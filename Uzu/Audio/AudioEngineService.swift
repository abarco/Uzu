import AVFoundation

/// Events pushed to the UI layer for things that happen outside a direct call —
/// interruptions, route changes, playback finishing on its own.
enum AudioEngineEvent: Sendable {
    case playbackFinished
    case recordingStoppedExternally(result: OverdubResult, reason: RecordingStopReason)
}

enum RecordingStopReason: Sendable {
    case interrupted     // phone call, Siri, alarm — partial take goes to review
    case routeChanged    // mic/route changed mid-take — take is discarded (user error)
    case micMuted        // system mic-mute (Control Center / AirPods stem) — partial to review
}

/// What a finished take measured: file duration and its latency-compensated
/// placement on the mix timeline (negative = file head precedes mix zero,
/// which is normal: it contains the count-in).
struct OverdubResult: Sendable {
    var duration: TimeInterval
    var startOffset: TimeInterval
}

/// The single owner of AVAudioEngine and AVAudioSession (see CLAUDE.md
/// § Architecture). Recording is always an "overdub": count-in clicks, then
/// all existing tracks play sample-synchronized while the mic records. The
/// first part is simply an overdub over an empty mix.
actor AudioEngineService {
    /// One engine owner for the whole app: view models come and go with the
    /// projects screen, the audio stack does not.
    static let shared = AudioEngineService()

    // Recreated (not reused) for every session start and after route/config
    // changes: a fresh engine derives all IO formats from the current route,
    // so stale taps/formats can never survive into the next start (the
    // -10868 "formats don't match" crash family).
    private var engine = AVAudioEngine()
    private let recorder = RecorderService()
    private let playback = PlaybackGraph()
    private let click = ClickTrack()

    private var sessionConfigured = false
    private var notificationObservers: [NSObjectProtocol] = []
    private var eventHandler: (@Sendable (AudioEngineEvent) -> Void)?

    /// Everything needed to (re)start the current take — kept so a route flip
    /// at record-start can restart the whole overdub transparently.
    private struct OverdubContext {
        let url: URL
        let items: [MixItem]
        let countInBeats: Int
        let beatInterval: TimeInterval
        var countInDuration: TimeInterval { Double(countInBeats) * beatInterval }
    }
    private var overdubContext: OverdubContext?
    private var mixZeroHostSeconds: TimeInterval?
    private var latenciesAtStart: (input: TimeInterval, output: TimeInterval) = (0, 0)
    private var autoRestartCount = 0

    var isRecording: Bool { recorder.isRecording }

    // MARK: - Setup

    /// Registers the UI event sink and starts watching session notifications.
    /// Call once at startup.
    func activate(eventHandler: @escaping @Sendable (AudioEngineEvent) -> Void) {
        self.eventHandler = eventHandler
        observeSessionNotifications()
    }

    func configureSessionIfNeeded() throws {
        guard !sessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // .defaultToSpeaker: review through the loudspeaker instead of the
            // barely-audible earpiece. Headphones/BT still take priority when
            // connected; the headphone warning covers speaker-bleed.
            try session.setCategory(
                .playAndRecord, mode: .default,
                options: [.allowBluetoothHFP, .defaultToSpeaker])
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

    /// True when playback would come out of the built-in speaker (the
    /// "use headphones" warning case for overdubs).
    var outputIsBuiltInSpeaker: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .builtInSpeaker }
    }

    // MARK: - Overdub (the only way to record)

    /// Starts the full overdub sequence: count-in clicks at the anchor, all
    /// `items` starting together at mix zero (anchor + count-in), and the mic
    /// recording throughout. Returns the count-in duration for the UI
    /// countdown.
    func startOverdub(
        items: [MixItem], recordTo url: URL, countInBeats: Int = 4,
        beatInterval: TimeInterval = 0.6
    ) throws -> TimeInterval {
        try configureSessionIfNeeded()
        autoRestartCount = 0
        let context = OverdubContext(
            url: url, items: items, countInBeats: countInBeats, beatInterval: beatInterval)
        overdubContext = context
        try startOverdubCore()
        return context.countInDuration
    }

    /// Ordering matters (each step guards against a distinct crash):
    /// fresh engine → touch input node (graph must not start empty) → attach
    /// players/click → start engine → schedule everything against one anchor →
    /// install the tap using the now-live input format.
    private func startOverdubCore() throws {
        guard let context = overdubContext else { return }
        rebuildEngine()
        recorder.attachInput(engine: engine)
        click.prepare(engine: engine)
        try playback.prepare(items: context.items, engine: engine, onAllFinished: {
            // Backing tracks ending while recording continues is normal; the
            // take keeps going until the user stops it.
        })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw UzuError.engineStartFailed(underlying: error)
        }

        guard let renderTime = engine.outputNode.lastRenderTime,
            renderTime.isSampleTimeValid, renderTime.isHostTimeValid
        else {
            engine.stop()
            throw UzuError.engineStartFailed(
                underlying: NSError(
                    domain: "com.uzu.app", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No render clock after engine start"]))
        }
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let anchor = renderTime.sampleTime + AVAudioFramePosition((0.2 * sampleRate).rounded())
        let mixZeroSample =
            anchor
            + AVAudioFramePosition((context.countInDuration * sampleRate).rounded())
        mixZeroHostSeconds = LatencyMath.hostSeconds(
            ofSample: mixZeroSample,
            referenceSample: renderTime.sampleTime,
            referenceHostSeconds: AVAudioTime.seconds(forHostTime: renderTime.hostTime),
            sampleRate: sampleRate)

        let session = AVAudioSession.sharedInstance()
        latenciesAtStart = (session.inputLatency, session.outputLatency)

        click.scheduleAndPlay(
            beats: context.countInBeats, anchor: anchor,
            interval: context.beatInterval, sampleRate: sampleRate)
        playback.begin(engine: engine, anchor: mixZeroSample, sampleRate: sampleRate)

        do {
            try recorder.beginWriting(engine: engine, url: context.url)
        } catch let error as UzuError {
            rebuildEngine()
            throw error
        } catch {
            rebuildEngine()
            try? FileManager.default.removeItem(at: context.url)
            throw UzuError.recordingWriteFailed(underlying: error)
        }
        Log.record.info(
            "Overdub started → \(context.url.lastPathComponent, privacy: .public), \(context.items.count) backing track(s), inLat=\(self.latenciesAtStart.input) outLat=\(self.latenciesAtStart.output)"
        )
    }

    /// Stops a user-requested take and returns its duration + placement.
    func stopOverdub() -> OverdubResult {
        let result = finalizeTakeMeasurements()
        overdubContext = nil
        rebuildEngine()
        Log.record.info(
            "Overdub stopped: \(result.duration, format: .fixed(precision: 2))s, applied latency offset \(result.startOffset, format: .fixed(precision: 4))s"
        )
        return result
    }

    /// Reads duration and computes the latency-compensated start offset for
    /// the take that is currently (or was just) recording.
    private func finalizeTakeMeasurements() -> OverdubResult {
        let duration = recorder.stop(engine: engine)
        let startOffset: TimeInterval
        if let recordedStart = recorder.recordedStartHostSeconds,
            let mixZero = mixZeroHostSeconds {
            startOffset = LatencyMath.overdubStartOffset(
                recordedStartTime: recordedStart,
                mixZeroTime: mixZero,
                inputLatency: latenciesAtStart.input,
                outputLatency: latenciesAtStart.output)
        } else {
            startOffset = 0
        }
        return OverdubResult(duration: duration, startOffset: startOffset)
    }

    /// Shared path for takes cut short from outside. A route flip while the
    /// take has barely begun (count-in + a beat — the normal Bluetooth
    /// record-start dance) restarts the whole overdub transparently on the new
    /// route. Everything else ends the take and informs the UI.
    private func handleRecordingDisrupted(reason: RecordingStopReason) {
        guard let context = overdubContext else { return }
        let result = finalizeTakeMeasurements()
        rebuildEngine()
        let graceWindow = context.countInDuration + 0.5
        if reason == .routeChanged, result.duration < graceWindow, autoRestartCount < 2 {
            autoRestartCount += 1
            do {
                try startOverdubCore()
                Log.record.info("Overdub auto-restarted on new route (attempt \(self.autoRestartCount))")
                return
            } catch {
                Log.record.error("Auto-restart after route change failed: \(error)")
            }
        }
        overdubContext = nil
        eventHandler?(.recordingStoppedExternally(result: result, reason: reason))
    }

    // MARK: - Playback

    /// Plays any number of tracks sample-synchronized against a shared anchor.
    /// A single item is just a mix of one (used for per-track preview).
    func playMix(_ items: [MixItem]) throws {
        try configureSessionIfNeeded()
        if recorder.isRecording { return }
        guard !items.isEmpty else { return }
        let handler = eventHandler
        rebuildEngine()
        try playback.prepare(items: items, engine: engine) {
            handler?(.playbackFinished)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            playback.stop(engine: engine)
            throw UzuError.engineStartFailed(underlying: error)
        }
        guard let renderTime = engine.outputNode.lastRenderTime,
            renderTime.isSampleTimeValid
        else {
            playback.stop(engine: engine)
            engine.stop()
            throw UzuError.engineStartFailed(
                underlying: NSError(
                    domain: "com.uzu.app", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No render clock after engine start"]))
        }
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let anchor = renderTime.sampleTime + AVAudioFramePosition((0.15 * sampleRate).rounded())
        playback.begin(engine: engine, anchor: anchor, sampleRate: sampleRate)
    }

    /// Live per-track volume while a mix is playing (mute = volume 0).
    func setTrackVolume(_ volume: Float, trackID: UUID) {
        playback.setVolume(volume, trackID: trackID)
    }

    // MARK: - Export

    /// Offline-renders the mix to an M4A. The realtime engine must not run
    /// during manual rendering (see CLAUDE.md gotchas), so everything is torn
    /// down first; the next play/record starts a fresh engine as usual.
    func exportMix(_ items: [MixItem], to url: URL, sampleRate: Double) throws -> ExportService.Result {
        guard !recorder.isRecording else {
            throw UzuError.exportFailed(
                underlying: NSError(
                    domain: "com.uzu.app", code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Can't export while recording"]))
        }
        rebuildEngine()
        Log.export.info("Export begin: \(items.count) track(s) → \(url.lastPathComponent, privacy: .public)")
        return try ExportService().export(items: items, to: url, sampleRate: sampleRate)
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
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(
                    .shouldResume)
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

        // System mic-mute (Control Center, Action button, AirPods stem): iOS
        // keeps delivering buffers of pure silence, so an unnoticed mute would
        // quietly ruin the take.
        let inputMute = center.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: nil
        ) { note in
            let muted = (note.userInfo?[AVAudioApplication.muteStateKey] as? Bool) ?? false
            Task { [weak self] in
                await self?.handleInputMuteChange(muted: muted)
            }
        }

        notificationObservers = [interruption, routeChange, configChange, inputMute]
    }

    private func handleInputMuteChange(muted: Bool) {
        Log.session.warning("Input mute state changed: muted=\(muted) (recording=\(self.recorder.isRecording))")
        guard muted, recorder.isRecording else { return }
        handleRecordingDisrupted(reason: .micMuted)
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            Log.session.warning("Interruption began (recording=\(self.recorder.isRecording))")
            if recorder.isRecording {
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

    // MARK: - Helpers

    /// Discards the current engine instance and creates a fresh one, finalizing
    /// any recording/playback still attached to the old instance first.
    private func rebuildEngine() {
        if recorder.isRecording {
            _ = recorder.stop(engine: engine)
        }
        playback.stop(engine: engine)
        click.stop(engine: engine)
        if engine.isRunning { engine.stop() }
        engine = AVAudioEngine()
        Log.engine.info("Engine rebuilt")
    }

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
