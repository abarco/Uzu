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
    /// `duration` is the AUDIBLE length. A negative offset means the file's
    /// head is skipped and the audible part starts at mix zero, so only
    /// positive offsets push a track's end later.
    static func mixDuration(of tracks: [Track]) -> TimeInterval {
        tracks.map { max(0, $0.startOffset) + $0.duration }.max() ?? 0
    }

    /// How to schedule one track against the shared anchor, supporting
    /// negative offsets (overdubs whose file begins before mix zero: count-in
    /// plus latency compensation).
    struct TrackPlacement: Equatable {
        /// Output-clock sample time at which the node starts playing.
        var startSampleTime: AVAudioFramePosition
        /// Frames of the source file to skip (in the FILE's sample rate).
        var sourceSkipFrames: AVAudioFramePosition
    }

    /// Positive offset → start later, play the whole file.
    /// Negative offset → start at the anchor, skip the file's head.
    static func placement(
        anchor: AVAudioFramePosition,
        outputSampleRate: Double,
        fileSampleRate: Double,
        startOffset: TimeInterval
    ) -> TrackPlacement {
        if startOffset >= 0 {
            return TrackPlacement(
                startSampleTime: anchor
                    + AVAudioFramePosition((startOffset * outputSampleRate).rounded()),
                sourceSkipFrames: 0)
        }
        return TrackPlacement(
            startSampleTime: anchor,
            sourceSkipFrames: AVAudioFramePosition((-startOffset * fileSampleRate).rounded()))
    }
}
