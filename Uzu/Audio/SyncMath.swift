import AVFoundation

/// Pure math for sample-synchronized playback starts. Kept free of any engine
/// state so it is unit-testable (see CLAUDE.md § Testing strategy, layer 1).
enum SyncMath {
    /// Sample time at which a track must start so that every track shares the
    /// same anchor: `anchor + startOffset` expressed in samples.
    ///
    /// Negative offsets are clamped to the anchor — a track can't start in the
    /// past; latency compensation (phase 3) yields small positive offsets.
    static func startSampleTime(
        anchor: AVAudioFramePosition,
        sampleRate: Double,
        startOffset: TimeInterval
    ) -> AVAudioFramePosition {
        let offsetSamples = AVAudioFramePosition((max(0, startOffset) * sampleRate).rounded())
        return anchor + offsetSamples
    }

    /// Total mix length: the furthest point any track reaches.
    static func mixDuration(of tracks: [Track]) -> TimeInterval {
        tracks.map { $0.startOffset + $0.duration }.max() ?? 0
    }
}
