import Foundation
import Testing

@testable import Uzu

struct LatencyMathTests {
    @Test func perfectlySimultaneousStartShiftsEarlierByLatencies() {
        // Recording began exactly at mix zero; user heard everything
        // outputLatency late and the mic added inputLatency.
        let offset = LatencyMath.overdubStartOffset(
            recordedStartTime: 100.0, mixZeroTime: 100.0,
            inputLatency: 0.004, outputLatency: 0.011)
        #expect(abs(offset - -0.015) < 1e-9)
    }

    @Test func recordingStartedBeforeMixZero() {
        // Tap started 2.4 s early (during the count-in): the file's head must
        // shift 2.4 s + latencies before mix zero.
        let offset = LatencyMath.overdubStartOffset(
            recordedStartTime: 97.6, mixZeroTime: 100.0,
            inputLatency: 0.005, outputLatency: 0.010)
        #expect(abs(offset - -2.415) < 1e-9)
    }

    @Test func zeroLatenciesReduceToPureTimeDifference() {
        let offset = LatencyMath.overdubStartOffset(
            recordedStartTime: 50.25, mixZeroTime: 50.0,
            inputLatency: 0, outputLatency: 0)
        #expect(abs(offset - 0.25) < 1e-9)
    }

    @Test func bluetoothScaleLatencies() {
        // BT round-trips are an order of magnitude larger; the math is the same.
        let offset = LatencyMath.overdubStartOffset(
            recordedStartTime: 10.0, mixZeroTime: 10.0,
            inputLatency: 0.08, outputLatency: 0.15)
        #expect(abs(offset - -0.23) < 1e-9)
    }

    @Test func hostSecondsExtrapolatesFromReference() {
        // Reference: sample 48_000 at t=2.0 s, 48 kHz → sample 96_000 is t=3.0 s.
        let t = LatencyMath.hostSeconds(
            ofSample: 96_000, referenceSample: 48_000,
            referenceHostSeconds: 2.0, sampleRate: 48_000)
        #expect(abs(t - 3.0) < 1e-9)
        // And backwards in time.
        let earlier = LatencyMath.hostSeconds(
            ofSample: 0, referenceSample: 48_000,
            referenceHostSeconds: 2.0, sampleRate: 48_000)
        #expect(abs(earlier - 1.0) < 1e-9)
    }
}
