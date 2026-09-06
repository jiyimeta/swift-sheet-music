package io.github.jiyimeta.sheetmusic.audio.model

/**
 * One level reading of the mix, in linear amplitude where `1.0` is 0 dBFS.
 * Mirrors Swift's `MixLevel`.
 *
 * The two numbers answer different questions and are easy to confuse. [peak] is
 * what clips — it decides how much master gain the mix can still take. [rms] is
 * what sounds loud. Their ratio is the crest factor, and a wide one is why a
 * mix can sit right at the ceiling and still feel quiet: raising the gain
 * cannot fix that, because [peak] hits the ceiling long before [rms] becomes
 * satisfying.
 *
 * @property peak largest sample magnitude in the buffer. Unclamped, so a value
 *   over `1.0` reports real overshoot past full scale. The device's volume
 *   control sits *downstream* and can only attenuate, so headroom has to be
 *   found before this point.
 * @property rms root mean square across every channel and frame.
 */
data class MixLevel(val peak: Float, val rms: Float) {
    companion object {
        /** Silence — what a monitor reports for a buffer that is entirely zero. */
        val SILENT = MixLevel(peak = 0f, rms = 0f)
    }
}
