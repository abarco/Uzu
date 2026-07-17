import AVFoundation
import Foundation
import Testing

@testable import Uzu

struct AudioFileEditorTests {
    private let sampleRate = 48_000.0

    /// 1 s of 440 Hz followed by 1 s of 880 Hz.
    private func makeTwoToneFixture(in folder: URL) throws -> URL {
        let url = folder.appending(path: "twotone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for (frequency, _) in [(440.0, 0), (880.0, 1)] {
            let frames = AVAudioFrameCount(sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![0][frame] =
                    Float(sin(2 * .pi * frequency * Double(frame) / sampleRate) * 0.5)
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "UzuEditorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func goertzelPower(_ url: URL, frequency: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(
            UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let rate = file.processingFormat.sampleRate
        let coefficient = 2 * cos(2 * .pi * frequency / rate)
        var s1 = 0.0, s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return power / Double(samples.count * samples.count)
    }

    @Test func extractedRegionHasRequestedDuration() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try makeTwoToneFixture(in: folder)
        let destination = folder.appending(path: "trimmed.caf")

        try AudioFileEditor.extractRegion(
            source: source, destination: destination, startSeconds: 0.5, durationSeconds: 1.0)

        let output = try AVAudioFile(forReading: destination)
        let duration = Double(output.length) / output.processingFormat.sampleRate
        #expect(abs(duration - 1.0) < 0.01)
    }

    @Test func trimmingHeadRemovesEarlyContent() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try makeTwoToneFixture(in: folder)
        let destination = folder.appending(path: "tail.caf")

        // Keep only the second half: 880 Hz should dominate, 440 Hz gone.
        try AudioFileEditor.extractRegion(
            source: source, destination: destination, startSeconds: 1.0, durationSeconds: 1.0)

        let p440 = try goertzelPower(destination, frequency: 440)
        let p880 = try goertzelPower(destination, frequency: 880)
        #expect(p880 > 1e-4)
        #expect(p440 < p880 / 1_000)
    }

    @Test func regionPastEndIsClamped() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try makeTwoToneFixture(in: folder)
        let destination = folder.appending(path: "clamped.caf")

        try AudioFileEditor.extractRegion(
            source: source, destination: destination, startSeconds: 1.5, durationSeconds: 5.0)

        let output = try AVAudioFile(forReading: destination)
        let duration = Double(output.length) / output.processingFormat.sampleRate
        #expect(abs(duration - 0.5) < 0.01)
    }

    @Test func regionOutsideFileThrows() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try makeTwoToneFixture(in: folder)
        let destination = folder.appending(path: "bad.caf")

        #expect(throws: (any Error).self) {
            try AudioFileEditor.extractRegion(
                source: source, destination: destination, startSeconds: 10, durationSeconds: 1)
        }
    }
}
