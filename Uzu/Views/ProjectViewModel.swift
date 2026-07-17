import AVFAudio
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ProjectViewModel {
    enum MicPermission {
        case unknown, granted, denied
    }

    /// The overdub flow: idle → countIn → recording → review (Keep/Redo).
    enum OverdubStage: Equatable {
        case idle, countIn, recording, review
    }

    /// A finished take awaiting Keep/Redo.
    struct PendingTake: Equatable {
        var name: String
        var fileName: String
        var duration: TimeInterval
        var startOffset: TimeInterval
    }

    static let partPresets = ["Guitar", "Vocals", "Backup vocals", "Percussion"]
    static let countInBeats = 4
    static let beatInterval: TimeInterval = 0.6

    private(set) var project: SongProject?
    private(set) var micPermission: MicPermission = .unknown
    private(set) var overdubStage: OverdubStage = .idle
    private(set) var countInRemaining = 0
    private(set) var recordingElapsed: TimeInterval = 0
    private(set) var pendingTake: PendingTake?
    private(set) var isPreviewingTake = false
    /// True while a take is recording on the speaker with backing tracks
    /// muted to prevent bleed (no headphones connected).
    private(set) var backingMutedForSpeaker = false
    private(set) var playingTrackID: UUID?
    private(set) var isPlayingMix = false
    private(set) var playbackElapsed: TimeInterval = 0
    var errorMessage: String?

    var mixDuration: TimeInterval {
        SyncMath.mixDuration(of: project?.tracks ?? [])
    }

    private let store: ProjectStore
    private let audio = AudioEngineService()
    private var takeName: String?
    private var takeFileName: String?
    private var recordingTimerTask: Task<Void, Never>?
    private var playbackTimerTask: Task<Void, Never>?
    private var countInTask: Task<Void, Never>?

    init(store: ProjectStore = .standard()) {
        self.store = store
    }

    // MARK: - Lifecycle

    func onAppear() async {
        refreshMicPermission()
        await audio.activate { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        loadOrCreateProject()
    }

    private func loadOrCreateProject() {
        guard project == nil else { return }
        if let existing = store.loadAllProjects()
            .sorted(by: { $0.name < $1.name }).first {
            project = existing
            Log.ui.info("Loaded project \(existing.id, privacy: .public)")
        } else {
            do {
                project = try store.createProject(name: "My Song", sampleRate: 0)
            } catch {
                Log.store.error("Failed to create project: \(error)")
                errorMessage = "Couldn't create a project on disk."
            }
        }
    }

    // MARK: - Mic permission

    private func refreshMicPermission() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: micPermission = .granted
        case .denied: micPermission = .denied
        default: micPermission = .unknown
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Overdub flow

    /// Whether the pre-record "no headphones" notice applies: on the speaker
    /// AND there are tracks that would be muted during the take.
    func shouldExplainSpeakerMuting() async -> Bool {
        guard !(project?.tracks.isEmpty ?? true) else { return false }
        // The session must be live for the route to be meaningful.
        try? await audio.configureSessionIfNeeded()
        return await audio.outputIsBuiltInSpeaker
    }

    /// Starts the take: count-in, then recording over all existing tracks.
    func beginAddPart(named name: String) async {
        guard overdubStage == .idle, var project else { return }

        if micPermission != .granted {
            let granted = await AVAudioApplication.requestRecordPermission()
            micPermission = granted ? .granted : .denied
            guard granted else {
                Log.ui.warning("Mic permission denied")
                return
            }
        }

        await stopAllPlayback()

        do {
            try await audio.configureSessionIfNeeded()
            if project.sampleRate == 0 {
                project.sampleRate = await audio.hardwareSampleRate
                self.project = project
            }
            let fileName = "\(UUID().uuidString).caf"
            // No headphones → the speaker would bleed straight into the mic,
            // so the backing tracks are muted (still scheduled, volume 0, so
            // the timing math is identical). The count-in click stays audible.
            let onSpeaker = await audio.outputIsBuiltInSpeaker
            backingMutedForSpeaker = onSpeaker && !project.tracks.isEmpty
            var items = mixItems(for: project)
            if onSpeaker {
                for index in items.indices { items[index].isMuted = true }
            }
            let countInDuration = try await audio.startOverdub(
                items: items,
                recordTo: store.audioFileURL(fileName: fileName, projectID: project.id),
                countInBeats: Self.countInBeats,
                beatInterval: Self.beatInterval)
            takeName = name
            takeFileName = fileName
            overdubStage = .countIn
            runCountIn(duration: countInDuration)
        } catch let error as UzuError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn't start recording."
            Log.record.error("Unexpected overdub start failure: \(error)")
        }
    }

    private func runCountIn(duration: TimeInterval) {
        countInRemaining = Self.countInBeats
        countInTask?.cancel()
        countInTask = Task { [weak self] in
            for beat in stride(from: Self.countInBeats - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(Self.beatInterval))
                guard let self, !Task.isCancelled, self.overdubStage == .countIn else { return }
                if beat > 0 {
                    self.countInRemaining = beat
                } else {
                    self.overdubStage = .recording
                    self.startElapsedTimer()
                }
            }
        }
    }

    /// Stop button during count-in (cancels the take) or recording (ends it
    /// and moves to review).
    func stopTake() async {
        switch overdubStage {
        case .countIn:
            countInTask?.cancel()
            _ = await audio.stopOverdub()
            removeTakeFile()
            resetTakeState()
        case .recording:
            let result = await audio.stopOverdub()
            moveToReview(result: result)
        default:
            break
        }
    }

    private func moveToReview(result: OverdubResult) {
        stopElapsedTimer()
        countInTask?.cancel()
        // The file includes the count-in head (skipped on playback via the
        // negative startOffset); what the user cares about — and what we store
        // as Track.duration — is the audible part that lands in the mix.
        let audibleDuration = result.duration + min(0, result.startOffset)
        guard let takeName, let takeFileName, audibleDuration > 0 else {
            removeTakeFile()
            resetTakeState()
            errorMessage = "No audio was captured. Try recording again."
            return
        }
        pendingTake = PendingTake(
            name: takeName,
            fileName: takeFileName,
            duration: audibleDuration,
            startOffset: result.startOffset)
        overdubStage = .review
    }

    func keepTake() {
        guard var project, let take = pendingTake else { return }
        let track = Track(
            id: UUID(),
            name: uniqueName(for: take.name, in: project),
            fileName: take.fileName,
            gain: 1.0,
            isMuted: false,
            startOffset: take.startOffset,
            duration: take.duration,
            createdAt: Date()
        )
        project.tracks.append(track)
        self.project = project
        persist(project)
        Task { await stopTakePreview() }
        resetTakeState()
    }

    /// Throw the take away without recording a replacement.
    func discardTake() async {
        await stopTakePreview()
        removeTakeFile()
        resetTakeState()
    }

    func redoTake() async {
        guard let name = takeName ?? pendingTake?.name else { return }
        await stopTakePreview()
        removeTakeFile()
        resetTakeState()
        await beginAddPart(named: name)
    }

    /// Preview the pending take (mixed with nothing — just the take itself,
    /// with its count-in head skipped).
    func toggleTakePreview() async {
        guard let take = pendingTake, let project else { return }
        if isPreviewingTake {
            await stopTakePreview()
            return
        }
        let item = MixItem(
            trackID: UUID(),
            fileURL: store.audioFileURL(fileName: take.fileName, projectID: project.id),
            gain: 1.0,
            isMuted: false,
            startOffset: min(0, take.startOffset)
        )
        if await startPlayback(items: [item]) {
            isPreviewingTake = true
        }
    }

    private func stopTakePreview() async {
        if isPreviewingTake {
            await audio.stopPlayback()
            isPreviewingTake = false
        }
    }

    private func resetTakeState() {
        overdubStage = .idle
        pendingTake = nil
        takeName = nil
        takeFileName = nil
        countInRemaining = 0
        backingMutedForSpeaker = false
        stopElapsedTimer()
    }

    private func removeTakeFile() {
        guard let project, let fileName = takeFileName ?? pendingTake?.fileName else { return }
        try? FileManager.default.removeItem(
            at: store.audioFileURL(fileName: fileName, projectID: project.id))
    }

    private func mixItems(for project: SongProject) -> [MixItem] {
        project.tracks.map { track in
            MixItem(
                trackID: track.id,
                fileURL: store.audioFileURL(fileName: track.fileName, projectID: project.id),
                gain: track.gain,
                isMuted: track.isMuted,
                startOffset: track.startOffset
            )
        }
    }

    /// "Guitar", then "Guitar 2", "Guitar 3", … on repeats.
    private func uniqueName(for base: String, in project: SongProject) -> String {
        let existing = Set(project.tracks.map(\.name))
        if !existing.contains(base) { return base }
        var counter = 2
        while existing.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    // MARK: - Playback

    /// Solo preview of one track, raw gain but latency-aligned (count-in head
    /// skipped via its negative startOffset).
    func togglePlayback(for track: Track) async {
        if playingTrackID == track.id {
            await stopAllPlayback()
            return
        }
        guard let project else { return }
        let item = MixItem(
            trackID: track.id,
            fileURL: store.audioFileURL(fileName: track.fileName, projectID: project.id),
            gain: 1.0,
            isMuted: false,
            startOffset: min(0, track.startOffset)
        )
        if await startPlayback(items: [item]) {
            playingTrackID = track.id
        }
    }

    /// Master play/stop of the whole mix, sample-synchronized.
    func toggleMixPlayback() async {
        if isPlayingMix {
            await stopAllPlayback()
            return
        }
        guard let project, !project.tracks.isEmpty else { return }
        if await startPlayback(items: mixItems(for: project)) {
            isPlayingMix = true
            startPlaybackTimer()
        }
    }

    private func startPlayback(items: [MixItem]) async -> Bool {
        for item in items where !FileManager.default.fileExists(atPath: item.fileURL.path) {
            errorMessage = UzuError.trackFileMissing(trackID: item.trackID).userMessage
            return false
        }
        do {
            try await audio.playMix(items)
            return true
        } catch let error as UzuError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn't play."
            Log.playback.error("Play failed: \(error)")
        }
        return false
    }

    private func stopAllPlayback() async {
        await audio.stopPlayback()
        clearPlaybackState()
    }

    private func clearPlaybackState() {
        playingTrackID = nil
        isPlayingMix = false
        isPreviewingTake = false
        stopPlaybackTimer()
    }

    // MARK: - Track gain / mute

    func setGain(_ gain: Float, for trackID: UUID) {
        guard var project,
            let index = project.tracks.firstIndex(where: { $0.id == trackID })
        else { return }
        project.tracks[index].gain = gain
        self.project = project
        let muted = project.tracks[index].isMuted
        Task {
            await audio.setTrackVolume(muted ? 0 : gain, trackID: trackID)
        }
        persist(project)
    }

    func toggleMute(for trackID: UUID) {
        guard var project,
            let index = project.tracks.firstIndex(where: { $0.id == trackID })
        else { return }
        project.tracks[index].isMuted.toggle()
        self.project = project
        let track = project.tracks[index]
        Task {
            await audio.setTrackVolume(track.isMuted ? 0 : track.gain, trackID: trackID)
        }
        persist(project)
    }

    // MARK: - Deleting tracks

    func deleteTrack(_ track: Track) async {
        guard var project else { return }
        // Deleting from under an active mix/preview would leave dangling nodes.
        await stopAllPlayback()
        project.tracks.removeAll { $0.id == track.id }
        self.project = project
        try? FileManager.default.removeItem(
            at: store.audioFileURL(fileName: track.fileName, projectID: project.id))
        persist(project)
        Log.ui.info("Deleted track \(track.id, privacy: .public)")
    }

    private func persist(_ project: SongProject) {
        do {
            try store.save(project)
        } catch {
            Log.store.error("Failed to save project: \(error)")
            errorMessage = "Couldn't save your changes."
        }
    }

    // MARK: - Engine events

    private func handle(_ event: AudioEngineEvent) {
        switch event {
        case .playbackFinished:
            clearPlaybackState()
        case .recordingStoppedExternally(let result, let reason):
            switch reason {
            case .routeChanged:
                // One take = one microphone. A mid-take mic change is a user
                // error: discard, and say so.
                countInTask?.cancel()
                stopElapsedTimer()
                removeTakeFile()
                resetTakeState()
                errorMessage = "Recording discarded: the microphone changed during the take (headphones connected or disconnected). Pick one mic and record again."
            case .interrupted:
                moveToReview(result: result)
                if pendingTake != nil {
                    errorMessage = UzuError.interruptedWhileRecording.userMessage
                }
            case .micMuted:
                moveToReview(result: result)
                if pendingTake != nil {
                    errorMessage = "Recording stopped: the microphone was muted (Control Center or your headphones' mute). That's usually accidental — you can Keep or Redo the partial take."
                }
            }
        }
    }

    // MARK: - Timers

    private func startElapsedTimer() {
        recordingElapsed = 0
        let started = ContinuousClock.now
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.overdubStage == .recording else { return }
                let elapsed = started.duration(to: .now)
                self.recordingElapsed = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
            }
        }
    }

    private func stopElapsedTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingElapsed = 0
    }

    private func startPlaybackTimer() {
        playbackElapsed = 0
        let started = ContinuousClock.now
        playbackTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.isPlayingMix else { return }
                let elapsed = started.duration(to: .now)
                self.playbackElapsed = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimerTask?.cancel()
        playbackTimerTask = nil
        playbackElapsed = 0
    }
}
