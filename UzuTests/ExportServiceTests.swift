import AVFoundation
import Foundation
import Testing

@testable import Uzu

struct ExportServiceTests {
    private let sampleRate = 48_000.0

    // MARK: - Fixtures

    /// Writes a mono CAF containing a pure sine wave — the same shape a real
    /// recording takes on disk.
    private func makeSineFixture(
        frequency: Double, duration: Double, in folder: URL, named name: String
    ) throws -> URL {
        let url = folder.appending(path: name)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            samples[frame] = Float(sin(2 * .pi * frequency * Double(frame) / sampleRate) * 0.5)
        }
        try file.write(from: buffer)
        return url
    }

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "UzuExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Decodes the exported file into one mono float array.
    private func decode(_ url: URL) throws -> (samples: [Float], sampleRate: Double, duration: Double) {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer)
        let channels = Int(file.processingFormat.channelCount)
        let count = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channels {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<count {
                mono[frame] += data[frame] / Float(channels)
            }
        }
        return (
            mono, file.processingFormat.sampleRate,
            Double(file.length) / file.processingFormat.sampleRate
        )
    }

    /// Normalized Goertzel power at one frequency (dependency-free DFT probe).
    private func goertzelPower(_ samples: [Float], sampleRate: Double, frequency: Double) -> Double {
        let coefficient = 2 * cos(2 * .pi * frequency / sampleRate)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for sample in samples {
            s0 = Double(sample) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return power / Double(samples.count * samples.count)
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }

    // MARK: - Tests

    @Test func exportedMixHasCorrectDurationAndIsNotSilent() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let a = try makeSineFixture(frequency: 440, duration: 2.0, in: folder, named: "a.caf")
        let b = try makeSineFixture(frequency: 880, duration: 2.0, in: folder, named: "b.caf")
        let items = [
            MixItem(trackID: UUID(), fileURL: a, gain: 1, isMuted: false, startOffset: 0),
            MixItem(trackID: UUID(), fileURL: b, gain: 1, isMuted: false, startOffset: 0),
        ]

        let output = folder.appending(path: "mix.m4a")
        let result = try ExportService().export(items: items, to: output, sampleRate: sampleRate)

        #expect(abs(result.duration - 2.0) < 0.05)
        #expect(result.fileSizeBytes > 10_000)

        let decoded = try decode(output)
        // AAC adds encoder priming/padding; allow a small tolerance.
        #expect(abs(decoded.duration - 2.0) < 0.2)
        #expect(rms(decoded.samples) > 0.05)
        // Both frequencies present.
        let p440 = goertzelPower(decoded.samples, sampleRate: decoded.sampleRate, frequency: 440)
        let p880 = goertzelPower(decoded.samples, sampleRate: decoded.sampleRate, frequency: 880)
        #expect(p440 > 1e-4)
        #expect(p880 > 1e-4)
    }

    @Test func mutedTrackIsAbsentFromExport() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let audible = try makeSineFixture(frequency: 440, duration: 2.0, in: folder, named: "a.caf")
        let muted = try makeSineFixture(frequency: 880, duration: 2.0, in: folder, named: "b.caf")
        let items = [
            MixItem(trackID: UUID(), fileURL: audible, gain: 1, isMuted: false, startOffset: 0),
            MixItem(trackID: UUID(), fileURL: muted, gain: 1, isMuted: true, startOffset: 0),
        ]

        let output = folder.appending(path: "mix.m4a")
        _ = try ExportService().export(items: items, to: output, sampleRate: sampleRate)

        let decoded = try decode(output)
        let p440 = goertzelPower(decoded.samples, sampleRate: decoded.sampleRate, frequency: 440)
        let p880 = goertzelPower(decoded.samples, sampleRate: decoded.sampleRate, frequency: 880)
        #expect(p440 > 1e-4, "audible track's tone must be present")
        #expect(p880 < p440 / 1_000, "muted track's tone must be absent")
    }

    @Test func startOffsetsShiftTracksInTheExport() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // 1 s of 440 Hz starting at 0; 1 s of 880 Hz starting at 1.5 s.
        let first = try makeSineFixture(frequency: 440, duration: 1.0, in: folder, named: "a.caf")
        let second = try makeSineFixture(frequency: 880, duration: 1.0, in: folder, named: "b.caf")
        let items = [
            MixItem(trackID: UUID(), fileURL: first, gain: 1, isMuted: false, startOffset: 0),
            MixItem(trackID: UUID(), fileURL: second, gain: 1, isMuted: false, startOffset: 1.5),
        ]

        let output = folder.appending(path: "mix.m4a")
        let result = try ExportService().export(items: items, to: output, sampleRate: sampleRate)
        #expect(abs(result.duration - 2.5) < 0.05)

        let decoded = try decode(output)
        let rate = decoded.sampleRate
        // Window 0.2–0.8 s: only 440 Hz. Window 1.7–2.3 s: only 880 Hz.
        let early = Array(decoded.samples[Int(0.2 * rate)..<Int(0.8 * rate)])
        let late = Array(decoded.samples[Int(1.7 * rate)..<Int(2.3 * rate)])
        #expect(goertzelPower(early, sampleRate: rate, frequency: 440) > 1e-4)
        #expect(goertzelPower(early, sampleRate: rate, frequency: 880) < 1e-7)
        #expect(goertzelPower(late, sampleRate: rate, frequency: 880) > 1e-4)
        #expect(goertzelPower(late, sampleRate: rate, frequency: 440) < 1e-7)
    }

    @Test func negativeOffsetSkipsFileHeadInExport() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // 2 s file whose first second is "count-in" to be skipped.
        let file = try makeSineFixture(frequency: 440, duration: 2.0, in: folder, named: "a.caf")
        let items = [
            MixItem(trackID: UUID(), fileURL: file, gain: 1, isMuted: false, startOffset: -1.0)
        ]

        let output = folder.appending(path: "mix.m4a")
        let result = try ExportService().export(items: items, to: output, sampleRate: sampleRate)
        #expect(abs(result.duration - 1.0) < 0.05)
    }

    @Test func allMutedThrowsAndLeavesNoFile() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = try makeSineFixture(frequency: 440, duration: 1.0, in: folder, named: "a.caf")
        let items = [
            MixItem(trackID: UUID(), fileURL: file, gain: 1, isMuted: true, startOffset: 0)
        ]
        let output = folder.appending(path: "mix.m4a")

        #expect(throws: UzuError.self) {
            try ExportService().export(items: items, to: output, sampleRate: sampleRate)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
