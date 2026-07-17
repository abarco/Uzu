import AVFoundation
import os

/// Renders the mix offline (faster than real time, no audio hardware) to an
/// M4A/AAC file, honoring each track's gain, mute, and start offset — the
/// same placement math playback uses. Invoked only via `AudioEngineService`,
/// which stops the realtime engine first (offline rendering requires it).
///
/// Deliberately session-independent so unit tests can run it on the simulator
/// against generated fixtures.
final class ExportService {
    struct Result: Sendable {
        var duration: TimeInterval
        var fileSizeBytes: Int64
    }

    private static let signposter = OSSignposter(subsystem: "com.uzu.app", category: "export")

    func export(items: [MixItem], to outputURL: URL, sampleRate: Double) throws -> Result {
        let interval = Self.signposter.beginInterval("offline-render")
        defer { Self.signposter.endInterval("offline-render", interval) }
        let startedAt = ContinuousClock.now

        do {
            let result = try renderMix(items: items, to: outputURL, sampleRate: sampleRate)
            let wall = startedAt.duration(to: .now)
            Log.export.info("""
            Export done: \(result.duration, format: .fixed(precision: 2))s of audio, \
            \(result.fileSizeBytes) bytes, wall time \(wall.components.seconds).\(wall.components.attoseconds / Int64(1e16))s
            """)
            return result
        } catch {
            // Never leave a partial file behind; the project itself is untouched.
            try? FileManager.default.removeItem(at: outputURL)
            Log.export.error("Export failed: \(error)")
            throw UzuError.exportFailed(underlying: error)
        }
    }

    private func renderMix(items: [MixItem], to outputURL: URL, sampleRate: Double) throws -> Result {
        let audible = items.filter { !$0.isMuted }
        guard !audible.isEmpty else {
            throw NSError(
                domain: "com.uzu.app", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Nothing to export (all tracks muted)"])
        }

        let engine = AVAudioEngine()
        guard let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2)
        else {
            throw NSError(
                domain: "com.uzu.app", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Bad render format \(sampleRate) Hz"])
        }

        // Build the graph: one player per audible track, exactly like playback.
        struct ScheduledPlayer {
            let node: AVAudioPlayerNode
            let startSampleTime: AVAudioFramePosition
        }
        var players: [ScheduledPlayer] = []
        var totalFrames: AVAudioFramePosition = 0

        try engine.enableManualRenderingMode(
            .offline, format: renderFormat, maximumFrameCount: 4096)

        for item in audible {
            let file = try AVAudioFile(forReading: item.fileURL)
            let fileRate = file.processingFormat.sampleRate
            let placement = SyncMath.placement(
                anchor: 0, outputSampleRate: sampleRate,
                fileSampleRate: fileRate, startOffset: item.startOffset)
            let remaining = AVAudioFrameCount(max(0, file.length - placement.sourceSkipFrames))
            guard remaining > 0 else { continue }

            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.volume = item.gain
            if placement.sourceSkipFrames > 0 {
                node.scheduleSegment(
                    file, startingFrame: placement.sourceSkipFrames,
                    frameCount: remaining, at: nil)
            } else {
                node.scheduleFile(file, at: nil)
            }
            players.append(
                ScheduledPlayer(node: node, startSampleTime: placement.startSampleTime))

            let audibleSeconds = Double(remaining) / fileRate
            let endFrame = placement.startSampleTime
                + AVAudioFramePosition((audibleSeconds * sampleRate).rounded())
            totalFrames = max(totalFrames, endFrame)
        }

        guard totalFrames > 0, !players.isEmpty else {
            throw NSError(
                domain: "com.uzu.app", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Mix is empty"])
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)

        try engine.start()
        for player in players {
            player.node.play(
                at: AVAudioTime(sampleTime: player.startSampleTime, atRate: sampleRate))
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount)
        else {
            engine.stop()
            throw NSError(
                domain: "com.uzu.app", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate render buffer"])
        }

        while engine.manualRenderingSampleTime < totalFrames {
            let remaining = totalFrames - engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                try outputFile.write(from: buffer)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                fallthrough
            @unknown default:
                engine.stop()
                throw NSError(
                    domain: "com.uzu.app", code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Offline render error"])
            }
        }
        engine.stop()

        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        return Result(
            duration: Double(totalFrames) / sampleRate,
            fileSizeBytes: (attributes?[.size] as? Int64) ?? 0)
    }
}
