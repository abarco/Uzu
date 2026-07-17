import Foundation
import Testing

@testable import Uzu

struct SyncMathTests {
    @Test func zeroOffsetStartsAtAnchor() {
        #expect(SyncMath.startSampleTime(anchor: 1_000, sampleRate: 48_000, startOffset: 0) == 1_000)
    }

    @Test func offsetConvertsToSamplesAtRate() {
        // 0.5 s at 48 kHz = 24 000 samples.
        #expect(
            SyncMath.startSampleTime(anchor: 1_000, sampleRate: 48_000, startOffset: 0.5)
                == 25_000)
        // Same offset at 44.1 kHz lands differently.
        #expect(
            SyncMath.startSampleTime(anchor: 1_000, sampleRate: 44_100, startOffset: 0.5)
                == 23_050)
    }

    @Test func fractionalSamplesRound() {
        // 0.0125 s at 44.1 kHz = 551.25 samples → rounds to 551.
        #expect(
            SyncMath.startSampleTime(anchor: 0, sampleRate: 44_100, startOffset: 0.0125) == 551)
    }

    @Test func negativeOffsetClampsToAnchor() {
        #expect(
            SyncMath.startSampleTime(anchor: 500, sampleRate: 48_000, startOffset: -0.25) == 500)
    }

    @Test func mixDurationIsFurthestTrackEnd() {
        func track(offset: TimeInterval, duration: TimeInterval) -> Track {
            Track(
                id: UUID(), name: "t", fileName: "t.caf", gain: 1, isMuted: false,
                startOffset: offset, duration: duration, createdAt: Date())
        }
        #expect(SyncMath.mixDuration(of: []) == 0)
        // A later-starting short track can still end last.
        let tracks = [
            track(offset: 0, duration: 10),
            track(offset: 8, duration: 5),
            track(offset: 2, duration: 3),
        ]
        #expect(SyncMath.mixDuration(of: tracks) == 13)
    }

    @Test func placementPositiveOffsetStartsLaterPlaysAll() {
        let p = SyncMath.placement(
            anchor: 1_000, outputSampleRate: 48_000, fileSampleRate: 48_000, startOffset: 0.5)
        #expect(p == SyncMath.TrackPlacement(startSampleTime: 25_000, sourceSkipFrames: 0))
    }

    @Test func placementNegativeOffsetSkipsFileHead() {
        // File recorded 2.4 s before mix zero (count-in): starts AT the anchor,
        // skipping 2.4 s of the file, in the FILE's own sample rate.
        let p = SyncMath.placement(
            anchor: 1_000, outputSampleRate: 48_000, fileSampleRate: 24_000, startOffset: -2.4)
        #expect(p == SyncMath.TrackPlacement(startSampleTime: 1_000, sourceSkipFrames: 57_600))
    }

    @Test func placementZeroOffsetIsIdentity() {
        let p = SyncMath.placement(
            anchor: 42, outputSampleRate: 44_100, fileSampleRate: 44_100, startOffset: 0)
        #expect(p == SyncMath.TrackPlacement(startSampleTime: 42, sourceSkipFrames: 0))
    }

    @Test func negativeOffsetTrackEndsAtItsAudibleDuration() {
        // Overdub: file head (count-in) skipped, audible 5 s from mix zero.
        let overdub = Track(
            id: UUID(), name: "Vocals", fileName: "v.caf", gain: 1, isMuted: false,
            startOffset: -2.6, duration: 5, createdAt: Date())
        #expect(SyncMath.mixDuration(of: [overdub]) == 5)
    }

    @Test func mutedTracksStillCountTowardDuration() {
        var track = Track(
            id: UUID(), name: "t", fileName: "t.caf", gain: 1, isMuted: true,
            startOffset: 1, duration: 4, createdAt: Date())
        track.isMuted = true
        #expect(SyncMath.mixDuration(of: [track]) == 5)
    }
}
