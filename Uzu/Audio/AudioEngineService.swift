import AVFoundation

/// Events pushed to the UI layer for things that happen outside a direct call —
/// interruptions, route changes, playback finishing on its own.
enum AudioEngineEvent: Sendable {
    case playbackFinished
    case recordingStoppedExternally(duration: TimeInterval, reason: RecordingStopReason)
}

enum RecordingStopReason: Sendable {
    case interrupted     // phone call, Siri, alarm
    case routeChanged    // headphones yanked, device changed
}

/// The single owner of AVAudioEngine and AVAudioSession (see CLAUDE.md § Architecture).
/// Recorder, playback, and (later) export all go through this actor, which keeps
/// every engine mutation off the main thread.
actor AudioEngineService {
    // Recreated (not reused) for every session start and after route/config
    // changes: a fresh engine derives all IO formats from the current route,
    // so stale taps/formats can never survive into the next start (the
    // -10868 "formats don't match" crash family).
    private var engine = AVAudioEngine()
    private let recorder = RecorderService()
    private let playback = PlaybackGraph()

    private var sessionConfigured = false
    private var notificationObservers: [NSObjectProtocol] = []
    private var eventHandler: (@Sendable (AudioEngineEvent) -> Void)?

    // Auto-restart bookkeeping: a route flip right after record-start (BT
    // grabbing the session) restarts the take instead of killing it.
    private var currentRecordingURL: URL?
    private var autoRestartCount = 0

    var isRecording: Bool { recorder.isRecording }

    // MARK: - Setup

    /// Registers the UI event sink and starts watching session notifications.
    /// Call once at startup.
    func activate(eventHandler: @escaping @Sendable (AudioEngineEvent) -> Void) {
        self.eventHandler = eventHandler
        observeSessionNotifications()
    }

    /// `.playAndRecord` without `.defaultToSpeaker`: review through the receiver /
    /// headphones, not the loudspeaker, while recording flows are active.
    func configureSessionIfNeeded() throws {
        guard !sessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            throw UzuError.sessionConfigurationFailed(underlying: error)
        }
        sessionConfigured = true
        Log.session.info("""
        Session active: sampleRate=\(session.sampleRate) \
        inputLatency=\(session.inputLatency) outputLatency=\(session.outputLatency) \
        route=\(Self.routeDescription(session.currentRoute), privacy: .public)
        """)
    }

    var hardwareSampleRate: Double {
        AVAudioSession.sharedInstance().sampleRate
    }

    // MARK: - Recording

    func startRecording(to url: URL) throws {
        try configureSessionIfNeeded()
        playback.stop(engine: engine)
        autoRestartCount = 0
        currentRecordingURL = url
        try startEngineAndTap(to: url)
        Log.record.info("Recording started → \(url.lastPathComponent, privacy: .public)")
    }

    /// Ordering matters (each step guards against a distinct crash):
    /// 1. fresh engine — nothing from a previous route can leak in;
    /// 2. touch the input node — the engine must not start on an empty graph;
    /// 3. start the engine — only a running IO unit reports the true input format;
    /// 4. create the file + tap from that live format.
    private func startEngineAndTap(to url: URL) throws {
        rebuildEngine()
        recorder.attachInput(engine: engine)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw UzuError.engineStartFailed(underlying: error)
        }
        do {
            try recorder.beginWriting(engine: engine, url: url)
        } catch let error as UzuError {
            stopEngineIfIdle()
            throw error
        } catch {
            stopEngineIfIdle()
            try? FileManager.default.removeItem(at: url)
            throw UzuError.recordingWriteFailed(underlying: error)
        }
    }

    /// Stops a user-requested recording and returns the recorded duration.
    func stopRecording() -> TimeInterval {
        currentRecordingURL = nil
        let duration = recorder.stop(engine: engine)
        stopEngineIfIdle()
        Log.record.info("Recording stopped: \(duration, format: .fixed(precision: 2))s, latency offset applied: 0 (phase 1)")
        return duration
    }

    /// Shared path for recordings cut short from outside (route change,
    /// interruption). A route flip with (almost) nothing captured yet is the
    /// normal Bluetooth record-start dance — restart transparently on the new
    /// route instead of killing the take. Anything else finalizes the partial
    /// take and informs the UI (always, even for empty takes).
    private func handleRecordingDisrupted(reason: RecordingStopReason) {
        let duration = recorder.stop(engine: engine)
        rebuildEngine()
        if reason == .routeChanged, duration < 0.5, autoRestartCount < 2,
            let url = currentRecordingURL {
            autoRestartCount += 1
            do {
                try startEngineAndTap(to: url)
                Log.record.info("Recording auto-restarted on new route (attempt \(self.autoRestartCount))")
                return
            } catch {
                Log.record.error("Auto-restart after route change failed: \(error)")
            }
        }
        currentRecordingURL = nil
        eventHandler?(.recordingStoppedExternally(duration: duration, reason: reason))
    }

    // MARK: - Playback

    func play(fileURL: URL) throws {
        try configureSessionIfNeeded()
        if recorder.isRecording { return }  // phase 1: no playback while recording
        let handler = eventHandler
        // Same rules as recording: a fresh engine (a materialized input node
        // keeps stale route formats too), and a non-empty graph before starting.
        rebuildEngine()
        try playback.prepare(fileURL: fileURL, engine: engine) {
            handler?(.playbackFinished)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            playback.stop(engine: engine)
            throw UzuError.engineStartFailed(underlying: error)
        }
        playback.begin()
    }

    func stopPlayback() {
        playback.stop(engine: engine)
        stopEngineIfIdle()
    }

    // MARK: - Session notifications

    private func observeSessionNotifications() {
        guard notificationObservers.isEmpty else { return }
        let center = NotificationCenter.default

        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let shouldResume: Bool
            if let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            } else {
                shouldResume = false
            }
            Task { [weak self] in
                await self?.handleInterruption(began: type == .began, shouldResume: shouldResume)
            }
        }

        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            Task { [weak self] in
                await self?.handleRouteChange(reason: reason)
            }
        }

        // object: nil because the engine instance is recreated over time; the
        // posting engine's identity is forwarded so stale notifications from a
        // replaced instance can be ignored.
        let configChange = center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { note in
            let engineID = (note.object as AnyObject?).map(ObjectIdentifier.init)
            Task { [weak self] in
                await self?.handleEngineConfigurationChange(engineID: engineID)
            }
        }

        notificationObservers = [interruption, routeChange, configChange]
    }

    /// The engine invalidated its graph (typically a route change: BT connect,
    /// headphones unplugged). Finalize whatever was running and reset so the
    /// next start re-derives formats from the current route (see error case #5).
    private func handleEngineConfigurationChange(engineID: ObjectIdentifier?) {
        guard engineID == ObjectIdentifier(engine) else {
            Log.engine.info("Ignoring configuration change from a replaced engine")
            return
        }
        Log.engine.warning("Engine configuration change (recording=\(self.recorder.isRecording), playing=\(self.playback.isPlaying))")
        if recorder.isRecording {
            handleRecordingDisrupted(reason: .routeChanged)
        } else if playback.isPlaying {
            rebuildEngine()
            eventHandler?(.playbackFinished)
        } else {
            rebuildEngine()
        }
    }

    /// Discards the current engine instance and creates a fresh one, finalizing
    /// any recording/playback still attached to the old instance first.
    private func rebuildEngine() {
        if recorder.isRecording {
            _ = recorder.stop(engine: engine)
        }
        playback.stop(engine: engine)
        if engine.isRunning { engine.stop() }
        engine = AVAudioEngine()
        Log.engine.info("Engine rebuilt")
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            Log.session.warning("Interruption began (recording=\(self.recorder.isRecording))")
            if recorder.isRecording {
                // Finalize the partial take safely; the UI keeps it as a valid track.
                handleRecordingDisrupted(reason: .interrupted)
            } else if playback.isPlaying {
                rebuildEngine()
                eventHandler?(.playbackFinished)
            }
        } else {
            Log.session.info("Interruption ended (shouldResume=\(shouldResume))")
            if shouldResume {
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        let session = AVAudioSession.sharedInstance()
        let wasRecording = recorder.isRecording
        Log.session.log(
            level: wasRecording ? .error : .info,
            "Route change (\(String(describing: reason), privacy: .public)) → \(Self.routeDescription(session.currentRoute), privacy: .public), recording=\(wasRecording)"
        )
        // Latency values are wrong after a route change — never keep recording
        // through one. Near record-start this auto-restarts on the new route.
        if wasRecording, reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
            handleRecordingDisrupted(reason: .routeChanged)
        }
    }

    // MARK: - Helpers

    private func stopEngineIfIdle() {
        // Stopping the engine when idle releases the mic (no lingering orange dot).
        if !recorder.isRecording && !playback.isPlaying && engine.isRunning {
            engine.stop()
            Log.engine.info("Engine stopped (idle)")
        }
    }

    private static func routeDescription(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map(\.portType.rawValue).joined(separator: "+")
        let outputs = route.outputs.map(\.portType.rawValue).joined(separator: "+")
        return "in[\(inputs)] out[\(outputs)]"
    }
}
