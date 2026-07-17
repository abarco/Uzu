import AVFoundation
import Foundation
import Testing

@testable import Uzu

struct WaveformLoaderTests {
    private let sampleRate = 48_000.0

    /// 0.5 s silence, then 0.5 s loud sine.
    private func makeHalfSilentFixture(in folder: URL) throws -> URL {
        let url = folder.appending(path: "halfsilent.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let t = Double(frame) / sampleRate
            buffer.floatChannelData![0][frame] =
                t < 0.5 ? 0 : Float(sin(2 * .pi * 440 * t) * 0.8)
        }
        try file.write(from: buffer)
        return url
    }

    @Test func peaksReflectSilenceAndSignal() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "UzuWaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = try makeHalfSilentFixture(in: folder)
        let peaks = try WaveformLoader.peaks(fileURL: url, skipHeadSeconds: 0, binCount: 20)

        #expect(peaks.count == 20)
        // First bins (silence) flat, later bins (sine) tall.
        #expect(peaks[2] < 0.01)
        #expect(peaks[15] > 0.5)
    }

    @Test func skipHeadDropsTheSilentIntro() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "UzuWaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = try makeHalfSilentFixture(in: folder)
        let peaks = try WaveformLoader.peaks(fileURL: url, skipHeadSeconds: 0.5, binCount: 10)

        #expect(peaks.count == 10)
        // Entire remaining region is signal.
        #expect(peaks.allSatisfy { $0 > 0.3 })
    }

    @Test func emptyOrMissingRegionsReturnEmpty() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "UzuWaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = try makeHalfSilentFixture(in: folder)
        // Skip beyond the end of the file.
        let peaks = try WaveformLoader.peaks(fileURL: url, skipHeadSeconds: 5, binCount: 10)
        #expect(peaks.isEmpty)
    }
}
