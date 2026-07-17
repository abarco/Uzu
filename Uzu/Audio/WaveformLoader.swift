import AVFoundation

/// Computes peak bins for waveform thumbnails straight from the audio file —
/// no libraries (see CLAUDE.md phase 5). Pure file I/O, unit-testable.
enum WaveformLoader {
    /// Returns `binCount` peak values in 0…1 for the audible region of the
    /// file (skipping `skipHeadSeconds` — the count-in head of overdubs).
    static func peaks(
        fileURL: URL, skipHeadSeconds: Double, binCount: Int = 60
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: fileURL)
        let rate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((max(0, skipHeadSeconds) * rate).rounded())
        let totalFrames = max(0, file.length - startFrame)
        guard binCount > 0, totalFrames > 0 else { return [] }

        let framesPerBin = max(1, Int(totalFrames) / binCount)
        var bins = [Float](repeating: 0, count: binCount)

        file.framePosition = startFrame
        let chunkSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: chunkSize)
        else { return [] }

        var frameIndex = 0
        while true {
            try file.read(into: buffer, frameCount: chunkSize)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            for i in 0..<Int(buffer.frameLength) {
                let bin = min(binCount - 1, (frameIndex + i) / framesPerBin)
                let magnitude = abs(channel[i])
                if magnitude > bins[bin] { bins[bin] = magnitude }
            }
            frameIndex += Int(buffer.frameLength)
            if frameIndex >= Int(totalFrames) { break }
        }

        // Normalize so quiet takes still show shape (but keep true silence flat).
        if let maxPeak = bins.max(), maxPeak > 0.001 {
            bins = bins.map { $0 / maxPeak }
        }
        return bins
    }
}
