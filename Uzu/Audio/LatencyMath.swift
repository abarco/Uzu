import Foundation

/// Pure latency-compensation math (see CLAUDE.md § Architecture): kept free of
/// session/engine state so every branch is unit-testable with synthetic values.
enum LatencyMath {
    /// Where an overdubbed take belongs on the mix timeline.
    ///
    /// - `recordedStartTime`: host-clock time (seconds) of the first recorded
    ///   sample (from the first input-tap buffer's timestamp).
    /// - `mixZeroTime`: host-clock time at which the existing tracks started
    ///   playing (end of the count-in).
    /// - The user hears the mix `outputLatency` late and their sound reaches
    ///   the file `inputLatency` late, so the take must shift earlier by both.
    ///
    /// Negative results are expected: they mean "this file's first
    /// |offset| seconds precede mix zero" (count-in + latencies) and are
    /// rendered by skipping that much of the file (see SyncMath.placement).
    static func overdubStartOffset(
        recordedStartTime: TimeInterval,
        mixZeroTime: TimeInterval,
        inputLatency: TimeInterval,
        outputLatency: TimeInterval
    ) -> TimeInterval {
        (recordedStartTime - mixZeroTime) - (inputLatency + outputLatency)
    }

    /// Host-clock seconds of a given output-clock sample, extrapolated from a
    /// reference (sample, hostSeconds) pair captured off a render timestamp.
    static func hostSeconds(
        ofSample sample: Int64,
        referenceSample: Int64,
        referenceHostSeconds: TimeInterval,
        sampleRate: Double
    ) -> TimeInterval {
        referenceHostSeconds + Double(sample - referenceSample) / sampleRate
    }
}
