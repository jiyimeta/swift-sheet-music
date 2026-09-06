package io.github.jiyimeta.sheetmusic.audio.model

/**
 * What the master chain does with a mix the master gain has pushed past full
 * scale. Mirrors Swift's `MasterOutputStage`.
 *
 * Nothing here can rescue a mix that is already too loud — the device's volume
 * control sits downstream of all of it and can only attenuate. The choice is
 * only about *how* the excess is dealt with.
 */
enum class MasterOutputStage {
    /**
     * Leave the mix alone. Overshoot survives the graph intact and is clipped
     * where the audio meets the output device.
     *
     * The default, because it is the only option under which the master gain
     * behaves like a volume control the whole way up: louder in, louder out.
     * The cost is that past full scale the clipping is hard.
     */
    NONE,

    /**
     * Bend the peaks with a saturation curve — linear below -3 dBFS, then
     * asymptotic toward full scale.
     *
     * Ordinary playback is untouched, and loudness keeps rising as the gain
     * goes up, so the control still runs the right way. The cost is progressive
     * harmonic distortion instead of a hard edge.
     */
    SOFT_CLIP,

    /**
     * Present for parity with Swift's `MasterOutputStage.peakLimiter`, which
     * exists there only for hosts that depended on the engine's old
     * unconditional `AUPeakLimiter`. **On Android it behaves as [NONE].**
     *
     * Not an oversight and not worth implementing: a peak limiter holds its
     * ceiling by *reducing gain*, so above unity the master control runs
     * backwards — measured on a steady sine, 8x drive lands 2.4 dB quieter than
     * 1x. The Swift documentation calls it "kept for hosts that depended on the
     * old behaviour, but not recommended"; there is no such legacy on Android,
     * so there is nothing to be compatible with. The case exists so a host
     * sharing an enum across platforms compiles, and this doc is why it does
     * nothing.
     */
    PEAK_LIMITER,
}
