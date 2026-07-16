import AVFoundation

/// One AVAudioPlayerNode per playing file, routed through the main mixer.
/// Phase 1 plays a single track at a time; Phase 2 grows this into the full
/// sample-synchronized multi-track graph. Owned exclusively by `AudioEngineService`.
final class PlaybackGraph {
    private var player: AVAudioPlayerNode?

    var isPlaying: Bool { player != nil }

    /// Attaches and schedules a player for `fileURL` WITHOUT starting it.
    /// Must run before `engine.start()` so the engine never starts on an empty
    /// graph; the caller then starts the engine and calls `begin()`.
    func prepare(fileURL: URL, engine: AVAudioEngine, onFinish: @escaping @Sendable () -> Void) throws {
        stop(engine: engine)
        let file = try AVAudioFile(forReading: fileURL)
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
            onFinish()
        }
        player = node
        Log.playback.info("Prepared \(fileURL.lastPathComponent, privacy: .public) (\(Double(file.length) / file.processingFormat.sampleRate, format: .fixed(precision: 2))s)")
    }

    /// Starts the prepared player. The engine must be running.
    func begin() {
        player?.play()
    }

    func stop(engine: AVAudioEngine) {
        guard let node = player else { return }
        // The node may belong to an engine instance that has since been
        // replaced; only stop/detach if it is still attached to this one.
        if node.engine === engine {
            node.stop()
            engine.detach(node)
        }
        player = nil
        Log.playback.info("Playback stopped")
    }
}
