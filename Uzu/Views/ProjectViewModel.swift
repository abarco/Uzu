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

    private(set) var project: SongProject?
    private(set) var micPermission: MicPermission = .unknown
    private(set) var isRecording = false
    private(set) var recordingElapsed: TimeInterval = 0
    private(set) var playingTrackID: UUID?
    private(set) var isPlayingMix = false
    private(set) var playbackElapsed: TimeInterval = 0
    var errorMessage: String?

    var mixDuration: TimeInterval {
        SyncMath.mixDuration(of: project?.tracks ?? [])
    }

    private let store: ProjectStore
    private let audio = AudioEngineService()
    private var pendingRecordingFileName: String?
    private var recordingTimerTask: Task<Void, Never>?
    private var playbackTimerTask: Task<Void, Never>?

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

    // MARK: - Recording

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard var project else { return }

        if micPermission != .granted {
            let granted = await AVAudioApplication.requestRecordPermission()
            micPermission = granted ? .granted : .denied
            guard granted else {
                Log.ui.warning("Mic permission denied")
                return
            }
        }

        do {
            try await audio.configureSessionIfNeeded()
            if project.sampleRate == 0 {
                project.sampleRate = await audio.hardwareSampleRate
                self.project = project
            }
            let fileName = "\(UUID().uuidString).caf"
            let url = store.audioFileURL(fileName: fileName, projectID: project.id)
            try await audio.startRecording(to: url)
            pendingRecordingFileName = fileName
            isRecording = true
            startElapsedTimer()
        } catch let error as UzuError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn't start recording."
            Log.record.error("Unexpected start failure: \(error)")
        }
    }

    private func stopRecording() async {
        let duration = await audio.stopRecording()
        finalizeRecording(duration: duration)
    }

    /// Shared end-of-recording path for both user stops and external stops
    /// (interruption, route change): keep the take as a track and persist.
    private func finalizeRecording(duration: TimeInterval) {
        stopElapsedTimer()
        isRecording = false
        guard var project, let fileName = pendingRecordingFileName else { return }
        pendingRecordingFileName = nil

        guard duration > 0 else {
            // Nothing usable was written; remove the empty file and say so
            // instead of silently showing no new track.
            try? FileManager.default.removeItem(
                at: store.audioFileURL(fileName: fileName, projectID: project.id))
            errorMessage = "No audio was captured. Try recording again."
            return
        }

        // Highest existing "Part n" + 1, so deletions never cause duplicates.
        let nextNumber = 1 + (project.tracks
            .compactMap { Int($0.name.dropFirst("Part ".count)) }
            .max() ?? 0)
        let track = Track(
            id: UUID(),
            name: "Part \(nextNumber)",
            fileName: fileName,
            gain: 1.0,
            isMuted: false,
            startOffset: 0,  // latency compensation lands in phase 3
            duration: duration,
            createdAt: Date()
        )
        project.tracks.append(track)
        self.project = project
        do {
            try store.save(project)
        } catch {
            Log.store.error("Failed to save project after recording: \(error)")
            errorMessage = "The recording finished but couldn't be saved to the project."
        }
    }

    // MARK: - Playback

    /// Solo preview of one track, raw (ignores its mix gain/mute).
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
            startOffset: 0
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
        let items = project.tracks.map { track in
            MixItem(
                trackID: track.id,
                fileURL: store.audioFileURL(fileName: track.fileName, projectID: project.id),
                gain: track.gain,
                isMuted: track.isMuted,
                startOffset: track.startOffset
            )
        }
        if await startPlayback(items: items) {
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
        case .recordingStoppedExternally(let duration, let reason):
            switch reason {
            case .interrupted:
                finalizeRecording(duration: duration)
                errorMessage = UzuError.interruptedWhileRecording.userMessage
            case .routeChanged:
                // One take = one microphone. A mid-take mic change is a user
                // error: discard, and say so.
                discardPendingRecording()
                errorMessage = "Recording discarded: the microphone changed during the take (headphones connected or disconnected). Pick one mic and record again."
            case .micMuted:
                finalizeRecording(duration: duration)
                errorMessage = "Recording stopped: the microphone was muted (Control Center or your headphones' mute). That's usually accidental — unmute and record again."
            }
        }
    }

    /// Ends the recording UI state and removes the take's file without
    /// creating a track.
    private func discardPendingRecording() {
        stopElapsedTimer()
        isRecording = false
        guard let project, let fileName = pendingRecordingFileName else { return }
        pendingRecordingFileName = nil
        try? FileManager.default.removeItem(
            at: store.audioFileURL(fileName: fileName, projectID: project.id))
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

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        recordingElapsed = 0
        let started = ContinuousClock.now
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isRecording else { return }
                self.recordingElapsed = Double(
                    started.duration(to: .now).components.seconds
                ) + Double(started.duration(to: .now).components.attoseconds) / 1e18
            }
        }
    }

    private func stopElapsedTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
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
