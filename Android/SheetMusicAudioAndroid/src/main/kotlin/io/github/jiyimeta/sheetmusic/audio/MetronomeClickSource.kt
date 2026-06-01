package io.github.jiyimeta.sheetmusic.audio

import android.net.Uri

/**
 * Where the metronome's click sound comes from. Supplied by the host through
 * a [MetronomeClickProvider]. Mirrors the Swift `MetronomeClickSource` seam.
 *
 * Click samples are passed as raw WAV bytes (clicks are tiny — tens of KB —
 * and the host typically loads them from `assets`), so the click path stays
 * free of [Uri] and is unit-testable on the JVM. A full host SoundFont is
 * referenced by [Uri] instead, since it can be large.
 */
sealed interface MetronomeClickSource {
    /** Two PCM WAV blobs (strong downbeat / weak beat). */
    data class ClickSamples(val strongWav: ByteArray, val weakWav: ByteArray) : MetronomeClickSource {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is ClickSamples) return false
            return strongWav.contentEquals(other.strongWav) && weakWav.contentEquals(other.weakWav)
        }
        override fun hashCode(): Int = 31 * strongWav.contentHashCode() + weakWav.contentHashCode()
    }

    /** A host-supplied SoundFont, used verbatim. */
    data class SoundFont(val uri: Uri) : MetronomeClickSource

    /** Keep the current behavior: reuse the score's GM drum-kit SoundFont. */
    object DefaultGm : MetronomeClickSource
}

/**
 * Implemented by the host to choose the metronome's click sound. Returning
 * [MetronomeClickSource.DefaultGm] (or supplying no provider) preserves the
 * legacy GM drum-kit click.
 */
fun interface MetronomeClickProvider {
    fun metronomeClickSource(): MetronomeClickSource
}
