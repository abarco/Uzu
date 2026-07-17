import AVFoundation

/// What the graph needs to know about one track to place it in the mix.
struct MixItem: Sendable {
    var trackID: UUID
    var fileURL: URL
    var gain: Float
    var isMuted: Bool
    var startOffset: TimeInterval
}

/// One AVAudioPlayerNode per track, routed through the main mixer, all started
/// against a single shared AVAudioTime anchor — never sequential `play()`
/// calls, which drift (see CLAUDE.md gotchas). Owned exclusively by
/// `AudioEngineService`.
final class PlaybackGraph {
    private struct ActivePlayer {
        let trackID: UUID
        let node: AVAudioPlayerNode
        let startOffset: TimeInterval
    }

    private var players: [ActivePlayer] = []
    // Bumped on every prepare/stop so completion callbacks from a superseded
    // mix can't fire onFinish for the current one.
    private var generation = 0

    var isPlaying: Bool { !players.isEmpty }

    /// Attaches and schedules a player per item WITHOUT starting anything.
    /// Must run before `engine.start()` so the engine never starts on an empty
    /// graph; the caller then starts the engine and calls `begin(engine:)`.
    /// `onAllFinished` fires once after the last track finishes on its own.
    func prepare(
        items: [MixItem],
        engine: AVAudioEngine,
        onAllFinished: @escaping @Sendable () -> Void
    ) throws {
        stop(engine: engine)
        generation += 1
        let thisGeneration = generation

        let finishCounter = FinishCounter(target: items.count) { onAllFinished() }
        for item in items {
            let file = try AVAudioFile(forReading: item.fileURL)
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.volume = item.isMuted ? 0 : item.gain
            node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                finishCounter.increment(ifCurrent: thisGeneration) { [weak self] in
                    self?.generation ?? -1
                }
            }
            players.append(ActivePlayer(trackID: item.trackID, node: node, startOffset: item.startOffset))
        }
        Log.playback.info("Prepared mix of \(items.count) track(s)")
    }

    /// Starts every prepared player against one shared anchor. The engine must
    /// be running (the output node needs a valid render time).
    func begin(engine: AVAudioEngine) {
        guard let renderTime = engine.outputNode.lastRenderTime,
            renderTime.isSampleTimeValid
        else {
            // No valid render clock (should not happen with a running engine);
            // degrade to unanchored starts rather than not playing at all.
            Log.playback.error("No valid render time; starting unanchored")
            for player in players { player.node.play() }
            return
        }
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        // Anchor slightly in the future so every node has time to arm.
        let anchor = renderTime.sampleTime + AVAudioFramePosition((0.15 * sampleRate).rounded())
        for player in players {
            let startSample = SyncMath.startSampleTime(
                anchor: anchor, sampleRate: sampleRate, startOffset: player.startOffset)
            player.node.play(at: AVAudioTime(sampleTime: startSample, atRate: sampleRate))
        }
        Log.playback.info("Mix started: anchor=\(anchor) rate=\(sampleRate)")
    }

    /// Live volume update (also used for mute: volume 0).
    func setVolume(_ volume: Float, trackID: UUID) {
        players.first { $0.trackID == trackID }?.node.volume = volume
    }

    func stop(engine: AVAudioEngine) {
        guard !players.isEmpty else { return }
        generation += 1
        for player in players {
            // Nodes may belong to an engine instance that has been replaced;
            // only stop/detach those still attached to this one.
            if player.node.engine === engine {
                player.node.stop()
                engine.detach(player.node)
            }
        }
        players.removeAll()
        Log.playback.info("Playback stopped")
    }
}

/// Thread-safe completion counter: player completion callbacks arrive on an
/// internal audio queue, possibly concurrently.
private final class FinishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let target: Int
    private let onComplete: @Sendable () -> Void

    init(target: Int, onComplete: @escaping @Sendable () -> Void) {
        self.target = target
        self.onComplete = onComplete
    }

    func increment(ifCurrent generation: Int, currentGeneration: @escaping () -> Int) {
        lock.lock()
        count += 1
        let finished = count == target
        lock.unlock()
        if finished && generation == currentGeneration() {
            onComplete()
        }
    }
}
