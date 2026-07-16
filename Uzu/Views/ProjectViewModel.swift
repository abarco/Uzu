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
    var errorMessage: String?

    private let store: ProjectStore
    private let audio = AudioEngineService()
    private var pendingRecordingFileName: String?
    private var recordingTimerTask: Task<Void, Never>?

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

        let track = Track(
            id: UUID(),
            name: "Part \(project.tracks.count + 1)",
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

    func togglePlayback(for track: Track) async {
        if playingTrackID == track.id {
            await audio.stopPlayback()
            playingTrackID = nil
            return
        }
        guard let project else { return }
        let url = store.audioFileURL(fileName: track.fileName, projectID: project.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = UzuError.trackFileMissing(trackID: track.id).userMessage
            return
        }
        do {
            try await audio.play(fileURL: url)
            playingTrackID = track.id
        } catch let error as UzuError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn't play that track."
            Log.playback.error("Play failed: \(error)")
        }
    }

    // MARK: - Engine events

    private func handle(_ event: AudioEngineEvent) {
        switch event {
        case .playbackFinished:
            playingTrackID = nil
        case .recordingStoppedExternally(let duration, let reason):
            finalizeRecording(duration: duration)
            switch reason {
            case .interrupted:
                errorMessage = UzuError.interruptedWhileRecording.userMessage
            case .routeChanged:
                errorMessage = "Recording stopped because the audio route changed. Your partial take was kept."
            }
        }
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
}
