#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudioApple
    import Testing

    /// The soft-clip curve's contract. The properties asserted here are
    /// exactly the ones the peak limiter fails: staying out of the way
    /// below the knee, and never turning a louder input into a quieter
    /// output.
    @Suite("Soft clip curve")
    struct SoftClipTests {
        private let knee: Float = 0.7071068

        @Test("passes signals below the knee through untouched")
        func transparentBelowKnee() {
            for input: Float in [0, 0.1, 0.25, 0.5, 0.7] {
                #expect(SoftClip.apply(input, knee: knee) == input)
            }
        }

        @Test("preserves sign")
        func preservesSign() {
            #expect(SoftClip.apply(-0.5, knee: knee) == -0.5)
            #expect(SoftClip.apply(-2.0, knee: knee) < 0)
            #expect(
                SoftClip.apply(-2.0, knee: knee) == -SoftClip.apply(2.0, knee: knee),
            )
        }

        /// Turning the gain up must never turn the output down. The
        /// per-sample curve saturates — `tanh` reaches exactly 1 in
        /// `Float` past roughly 4x drive — so the guarantee is
        /// non-decreasing, not strictly increasing. What keeps rising past
        /// that point is loudness, covered by `loudnessKeepsRising`.
        @Test("never turns a louder sample into a quieter one")
        func neverGoesBackwards() {
            var previous = SoftClip.apply(knee, knee: knee)
            for input: Float in [0.8, 1.0, 1.2, 1.5, 2, 3, 4, 8, 16, 64] {
                let output = SoftClip.apply(input, knee: knee)
                #expect(output >= previous, "\(input) produced \(output) < \(previous)")
                previous = output
            }
        }

        /// The property the peak limiter fails outright: driving the stage
        /// harder has to make the *signal* louder. A clipped sine grows
        /// toward a square wave, so its RMS keeps climbing even once the
        /// peak has pinned to full scale. The limiter measured the other
        /// way — 8x drive was 2.4 dB quieter than 1x.
        @Test("loudness keeps rising as the stage is driven harder")
        func loudnessKeepsRising() {
            var previous: Float = 0
            for drive: Float in [0.5, 1, 1.5, 2, 3, 4, 6, 8] {
                let rms = clippedSineRMS(amplitude: drive)
                #expect(rms > previous, "drive \(drive) gave RMS \(rms) <= \(previous)")
                previous = rms
            }
        }

        @Test("never exceeds full scale, however hard it is driven")
        func neverExceedsFullScale() {
            #expect(SoftClip.apply(1000, knee: knee) <= 1.0)
            #expect(SoftClip.apply(1000, knee: knee) > 0.99)
        }

        /// RMS of one cycle of a sine at `amplitude`, soft-clipped.
        private func clippedSineRMS(amplitude: Float) -> Float {
            let samples = 4096
            var sumOfSquares: Float = 0
            for index in 0 ..< samples {
                let phase = 2 * Float.pi * Float(index) / Float(samples)
                let shaped = SoftClip.apply(amplitude * sin(phase), knee: knee)
                sumOfSquares += shaped * shaped
            }
            return (sumOfSquares / Float(samples)).squareRoot()
        }

        /// A kink at the knee would be audible, so the curve has to leave
        /// the linear region with the slope it arrived with.
        @Test("joins the linear region smoothly")
        func continuousAtTheKnee() {
            let delta: Float = 0.001
            let below = SoftClip.apply(knee - delta, knee: knee)
            let above = SoftClip.apply(knee + delta, knee: knee)
            let slope = (above - below) / (2 * delta)
            #expect(abs(slope - 1) < 0.01)
        }

        /// A knee at or above full scale leaves no room to curve into, so
        /// it degenerates to a hard clip rather than dividing by zero.
        @Test("a degenerate knee hard-clips instead of producing NaN")
        func degenerateKneeHardClips() {
            #expect(SoftClip.apply(2.0, knee: 1.0) == 1.0)
            #expect(SoftClip.apply(2.0, knee: 1.5) == 1.0)
            #expect(SoftClip.apply(-2.0, knee: 1.0) == -1.0)
            #expect(SoftClip.apply(0.5, knee: 1.0) == 0.5)
        }
    }
#endif
