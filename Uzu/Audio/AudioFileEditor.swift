import AVFoundation

/// File-level editing (trim) — pure file I/O, no engine or session involved,
/// so it is unit-testable on the simulator.
enum AudioFileEditor {
    /// Copies the region `[startSeconds, startSeconds + durationSeconds)` of
    /// `source` into a new file at `destination`, preserving the source's
    /// processing format. Used for destructive trim: the caller replaces the
    /// track's file and adjusts its metadata.
    static func extractRegion(
        source: URL, destination: URL, startSeconds: Double, durationSeconds: Double
    ) throws {
        let file = try AVAudioFile(forReading: source)
        let rate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((startSeconds * rate).rounded())
        let requested = AVAudioFramePosition((durationSeconds * rate).rounded())
        guard startFrame >= 0, startFrame < file.length, requested > 0 else {
            throw NSError(
                domain: "com.uzu.app", code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Trim region outside the file"])
        }
        let frameCount = AVAudioFrameCount(min(requested, file.length - startFrame))

        let output = try AVAudioFile(
            forWriting: destination, settings: file.processingFormat.settings)
        file.framePosition = startFrame

        let chunkSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: chunkSize)
        else {
            throw NSError(
                domain: "com.uzu.app", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate trim buffer"])
        }

        var remaining = frameCount
        while remaining > 0 {
            try file.read(into: buffer, frameCount: min(chunkSize, remaining))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= buffer.frameLength
        }
        Log.store.info("Trimmed \(source.lastPathComponent, privacy: .public) → \(destination.lastPathComponent, privacy: .public) (\(durationSeconds, format: .fixed(precision: 2))s)")
    }
}
