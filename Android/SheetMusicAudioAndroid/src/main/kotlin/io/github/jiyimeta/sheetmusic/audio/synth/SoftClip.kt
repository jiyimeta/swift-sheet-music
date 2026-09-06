package io.github.jiyimeta.sheetmusic.audio.synth

import kotlin.math.abs
import kotlin.math.tanh

/**
 * A saturation curve for the master output stage: linear below a knee, then
 * bending asymptotically toward full scale.
 *
 * A direct port of Swift's `SoftClip` (`Sources/SheetMusicAudioApple/SoftClip.swift`)
 * — same knee, same shaping, same degenerate case — so a score driven past
 * full scale sounds the same on both platforms. It is a port rather than a
 * shared implementation because the curve is four lines of arithmetic and
 * `SheetMusicAudioCore` would have to grow a DSP surface to hold it; the
 * coupling is recorded here and pinned by a test that checks the two agree at
 * the points that define the curve.
 *
 * It exists as an alternative to a peak limiter, whose gain reduction makes the
 * master gain control run *backwards* above unity. This curve is strictly
 * monotonic instead: louder in is always louder out, and the price is
 * progressive harmonic distortion rather than a moving gain. Below the knee it
 * does nothing at all, so ordinary playback is untouched.
 */
internal object SoftClip {

    /**
     * Where the curve leaves the linear region, in linear amplitude.
     *
     * -3 dBFS: high enough that normal material never reaches it, low enough to
     * leave room to bend in before full scale.
     */
    const val DEFAULT_KNEE: Float = 0.7071068f

    /**
     * Shape one sample.
     *
     * Below [knee] the sample is returned unchanged. Above it the excess is
     * passed through `tanh`, scaled so the curve leaves the knee with slope 1
     * (no audible kink) and approaches — but never reaches — full scale. At
     * exactly 0 dBFS in, the default knee gives about -0.6 dB out.
     *
     * A [knee] at or above full scale leaves nothing to bend into, so the curve
     * degenerates to a hard clip rather than dividing by zero.
     */
    fun apply(sample: Float, knee: Float = DEFAULT_KNEE): Float {
        val magnitude = abs(sample)
        if (magnitude <= knee) return sample
        if (knee >= 1f) return if (sample < 0f) -1f else 1f
        val headroom = 1f - knee
        val shaped = knee + headroom * tanh((magnitude - knee) / headroom)
        return if (sample < 0f) -shaped else shaped
    }
}
