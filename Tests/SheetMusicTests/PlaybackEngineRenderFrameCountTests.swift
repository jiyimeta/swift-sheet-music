#if !os(Android)
    import AVFoundation
    @testable import SheetMusicAudioApple
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
    }
#endif
