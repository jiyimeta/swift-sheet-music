#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    @testable import SheetMusicAudioApple
    import SheetMusicAudioCore
    import Testing

    /// Covers Gap B: `PlaybackEngine.renderFrameCount(durationSec:rate:sampleRate:)`
    /// is the extracted helper backing `exportAudioFile`'s `framesToRender`.
    /// `durationSec` is timeline-seconds at rate 1.0, but the export sequencer
    /// plays at `snapshot.rate`, so the render must span `durationSec / rate`
    /// wall-clock seconds — a rate < 1 (slow-practice export) needs MORE
    /// frames, not `durationSec * sampleRate` worth, or the render loop stops
    /// before the slowed piece finishes sounding (the bug this fixes). No
    /// real `AVAudioEngine` is involved, so this suite doesn't need to nest
    /// under `AudioEngineSerial`.
    @Suite("PlaybackEngine.renderFrameCount")
    @MainActor
    struct PlaybackEngineRenderFrameCountTests {
        @Test("rate 1.0 renders durationSec * sampleRate frames")
        func rateOneIsUnscaled() {
            let frames = PlaybackEngine.renderFrameCount(
                durationSec: 10, rate: 1.0, sampleRate: 44100,
            )
            #expect(frames == AVAudioFrameCount(10 * 44100))
        }

        @Test("rate 0.5 (slow-practice export) renders twice the frames")
        func rateHalfDoublesFrames() {
            let frames = PlaybackEngine.renderFrameCount(
                durationSec: 10, rate: 0.5, sampleRate: 44100,
            )
            #expect(frames == AVAudioFrameCount(20 * 44100))
        }

        @Test("rate 2.0 (double-speed export) renders half the frames")
        func rateDoubleHalvesFrames() {
            let frames = PlaybackEngine.renderFrameCount(
                durationSec: 10, rate: 2.0, sampleRate: 44100,
            )
            #expect(frames == AVAudioFrameCount(5 * 44100))
        }

        @Test("rate 0 is clamped to a small positive floor rather than crashing or blowing up")
        func rateZeroIsClamped() {
            // `rate` is floored to 0.01 by `max(rate, 0.01)`. Compare against an
            // explicit 0.01 rate (rather than a hand-duplicated formula) so the
            // assertion isn't sensitive to floating-point rounding artifacts in
            // `10 / 0.01`, which don't exactly cancel out with `.rounded(.up)`.
            let floored = PlaybackEngine.renderFrameCount(
                durationSec: 10, rate: 0.01, sampleRate: 44100,
            )
            let frames = PlaybackEngine.renderFrameCount(
                durationSec: 10, rate: 0, sampleRate: 44100,
            )
            #expect(frames == floored)
            // Sanity bound: clamped-to-floor must render dramatically MORE
            // frames than an unslowed (rate 1.0) export of the same duration —
            // not zero, not overflowing, not silently falling back to rate 1.0.
            #expect(frames > AVAudioFrameCount(10 * 44100))
        }

        @Test("a negative rate is clamped the same way as 0")
        func negativeRateIsClamped() {
            let floored = PlaybackEngine.renderFrameCount(
                durationSec: 10, rate: 0.01, sampleRate: 44100,
            )
            let frames = PlaybackEngine.renderFrameCount(
                durationSec: 10, rate: -2, sampleRate: 44100,
            )
            #expect(frames == floored)
        }

        @Test("zero duration renders zero frames regardless of rate")
        func zeroDurationRendersZeroFrames() {
            let frames = PlaybackEngine.renderFrameCount(
                durationSec: 0, rate: 0.5, sampleRate: 44100,
            )
            #expect(frames == 0)
        }

        @Test("a count-in goes in front as the wall-clock length it is handed, the allowance after")
        func countInAndAllowanceAddToTheBody() {
            let frames = PlaybackEngine.renderFrameCount(
                durationSec: 10, rate: 0.5, sampleRate: 44100, countInSeconds: 2.5, allowanceFrames: 36,
            )
            // `countInSeconds` is what the backend holds the score for — already at the rate, or at the warped speed
            // (`TransportSpeedTable.countIn`), so it is not divided again; the body is stretched by the rate.
            #expect(frames == AVAudioFrameCount(2.5 * 44100) + AVAudioFrameCount(20 * 44100) + 36)
        }

        @Test("without a span there is no drift allowance")
        func noWarpNoAllowance() {
            #expect(PlaybackEngine.warpDriftAllowanceFrames(table: TransportSpeedTable(warp: nil), from: 0, to: 8) == 0)
        }

        /// Stretches 0.8, 1, 2/3 and 0.8 over four 2 s measures; outside them 1. Half a 64-frame block × |Δ| ÷ the
        /// stretch after, per boundary: 8 at 0 (where the body starts, parked just before it), 6.4 at 2, 16 at 4 and
        /// 5.33 at 6 — the boundary at 8 is where the body ends, past which nothing is cut.
        @Test("the drift allowance sums each boundary the body crosses, from just before its start")
        func allowanceSumsTheBoundariesTheBodyCrosses() throws {
            let table = try TransportSpeedTable(warp: PlaybackTimeWarp(spans: [
                .init(start: 0, end: 2, duration: 2.5), .init(start: 2, end: 4, duration: 2),
                .init(start: 4, end: 6, duration: 3), .init(start: 6, end: 8, duration: 2.5),
            ]))
            #expect(PlaybackEngine.warpDriftAllowanceFrames(table: table, from: 0, to: 8) == 36)
            // A range of the second and third measures crosses the boundaries at 2 and 4: 6.4 + 16.
            #expect(PlaybackEngine.warpDriftAllowanceFrames(table: table, from: 2, to: 6) == 23)
        }
    }
#endif
