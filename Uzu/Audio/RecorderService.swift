import AVFoundation

/// Writes the input tap to a CAF file. Owned and driven exclusively by
/// `AudioEngineService`; never touches the session or starts the engine itself.
final class RecorderService {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var writeError: Error?
    private var firstBufferHostTime: UInt64?

    private(set) var isRecording = false

    /// Host-clock seconds of the first recorded sample, for latency-compensated
    /// placement. Nil until the first buffer arrives.
    var recordedStartHostSeconds: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return firstBufferHostTime.map { AVAudioTime.seconds(forHostTime: $0) }
    }

    /// Touches the input node so the engine graph is non-empty. Must be called
    /// BEFORE `engine.start()` — starting with an empty graph raises an
    /// unrecoverable NSException.
    func attachInput(engine: AVAudioEngine) {
        _ = engine.inputNode
    }

    /// Queries the live input format, creates the file, and installs the tap.
    /// Must be called AFTER `engine.start()`: before the IO unit runs,
    /// `outputFormat(forBus:)` can report a stale nominal rate (e.g. 48 kHz
    /// while a Bluetooth HFP mic actually runs at 16/24 kHz), and installing a
    /// tap with that format crashes with "Failed to create tap due to format
    /// mismatch". A running engine reports the true format.
    func beginWriting(engine: AVAudioEngine, url: URL) throws {
        let input = engine.inputNode
        // Always record in the hardware input format — never resample (see CLAUDE.md gotchas).
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw UzuError.recordingWriteFailed(
                underlying: NSError(
                    domain: "com.uzu.app", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Input format unavailable (no mic access?)"]
                ))
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        lock.lock()
        self.file = file
        self.writeError = nil
        self.firstBufferHostTime = nil
        lock.unlock()

        // format: nil → the tap always uses the node's current output format.
        // A mismatch can then only surface as a catchable file-write error,
        // never as an NSException at engine start.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, when in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let file = self.file else { return }
            if self.firstBufferHostTime == nil, when.isHostTimeValid {
                self.firstBufferHostTime = when.hostTime
            }
            do {
                try file.write(from: buffer)
            } catch {
                if self.writeError == nil {
                    self.writeError = error
                    Log.record.error("Buffer write failed: \(error)")
                }
            }
        }
        isRecording = true
    }

    /// Removes the tap and finalizes the file. Returns the recorded duration in
    /// seconds. Safe to call when not recording (returns 0).
    func stop(engine: AVAudioEngine) -> TimeInterval {
        guard isRecording else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false

        lock.lock()
        let duration = file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        // Releasing the AVAudioFile closes it; whatever was written stays valid.
        file = nil
        let hadWriteError = writeError != nil
        writeError = nil
        lock.unlock()

        if hadWriteError {
            Log.record.warning("Recording finalized after a write error; partial take kept (\(duration)s)")
        }
        return duration
    }
}
