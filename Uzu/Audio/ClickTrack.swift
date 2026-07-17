import AVFoundation

/// Generates and plays the count-in click: a short decaying sine burst,
/// synthesized at runtime (no bundled sample, zero dependencies). Owned
/// exclusively by `AudioEngineService`.
final class ClickTrack {
    private var node: AVAudioPlayerNode?
    private var buffer: AVAudioPCMBuffer?

    /// Attach the click player. Call before `engine.start()`.
    func prepare(engine: AVAudioEngine) {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate,
            channels: 1)!
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.node = node
        self.buffer = Self.makeClickBuffer(format: format)
    }

    /// Schedules `beats` ticks starting at `anchor`, `interval` seconds apart,
    /// and starts the player. The engine must be running.
    ///
    /// Timeline caution: `scheduleBuffer(at:)` times are in the PLAYER's own
    /// 0-based timeline, while `play(at:)` takes engine-output time. So each
    /// tick is scheduled at its beat offset (player time) and the player
    /// itself starts at the anchor (output time).
    func scheduleAndPlay(
        beats: Int, anchor: AVAudioFramePosition, interval: TimeInterval, sampleRate: Double
    ) {
        guard let node, let buffer else { return }
        for beat in 0..<beats {
            let beatOffset = AVAudioFramePosition((Double(beat) * interval * sampleRate).rounded())
            node.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: beatOffset, atRate: sampleRate))
        }
        node.play(at: AVAudioTime(sampleTime: anchor, atRate: sampleRate))
    }

    func stop(engine: AVAudioEngine) {
        guard let node else { return }
        if node.engine === engine {
            node.stop()
            engine.detach(node)
        }
        self.node = nil
        self.buffer = nil
    }

    /// 60 ms, 1 kHz, exponentially decaying — a classic metronome tick.
    private static func makeClickBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(0.06 * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let t = Double(frame) / sampleRate
            let envelope = exp(-t * 60)
            samples[frame] = Float(sin(2 * .pi * 1000 * t) * envelope * 0.8)
        }
        return buffer
    }
}
