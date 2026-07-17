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
        let fileSampleRate: Double
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
            let fileRate = file.processingFormat.sampleRate
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.volume = item.isMuted ? 0 : item.gain

            // Negative offsets (overdubs: count-in + latency shift) skip the
            // file's head instead of starting before the anchor.
            let skip = SyncMath.placement(
                anchor: 0, outputSampleRate: fileRate, fileSampleRate: fileRate,
                startOffset: item.startOffset
            ).sourceSkipFrames
            let remaining = AVAudioFrameCount(max(0, file.length - skip))
            let completion: (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
                finishCounter.increment(ifCurrent: thisGeneration) { [weak self] in
                    self?.generation ?? -1
                }
            }
            if remaining == 0 {
                // Nothing of this file lands after the anchor; count it done.
                finishCounter.increment(ifCurrent: thisGeneration) { [weak self] in
                    self?.generation ?? -1
                }
            } else if skip > 0 {
                node.scheduleSegment(
                    file, startingFrame: skip, frameCount: remaining, at: nil,
                    completionCallbackType: .dataPlayedBack, completionHandler: completion)
            } else {
                node.scheduleFile(
                    file, at: nil, completionCallbackType: .dataPlayedBack,
                    completionHandler: completion)
            }
            players.append(
                ActivePlayer(
                    trackID: item.trackID, node: node, startOffset: item.startOffset,
                    fileSampleRate: fileRate))
        }
        Log.playback.info("Prepared mix of \(items.count) track(s)")
    }

    /// Starts every prepared player against the given shared anchor
    /// (output-clock sample time). The engine must be running.
    func begin(engine: AVAudioEngine, anchor: AVAudioFramePosition, sampleRate: Double) {
        for player in players {
            let startSample = SyncMath.placement(
                anchor: anchor, outputSampleRate: sampleRate,
                fileSampleRate: player.fileSampleRate, startOffset: player.startOffset
            ).startSampleTime
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
