package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickProvider
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickSource
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import java.io.File

/**
 * Decides where the metronome's click sound comes from, mirroring Apple's
 * `MetronomeClickResolver`. The decision is returned as a Uri-free
 * [Resolution] so the dispatch logic is unit-testable on the JVM; turning a
 * [Resolution] into a loaded SoundFont (which needs [Context]/[Uri]) is the
 * separate [MetronomeSf2Loader] glue.
 */
internal class AndroidMetronomeClickResolver(
    private val provider: MetronomeClickProvider?,
    private val jniBridge: AndroidPlaybackEngine.JniBridge,
) {
    sealed interface Resolution {
        /** SF2 bytes built from the host's click WAVs. */
        data class GeneratedSf2(val bytes: ByteArray) : Resolution {
            override fun equals(other: Any?): Boolean =
                this === other || (other is GeneratedSf2 && bytes.contentEquals(other.bytes))
            override fun hashCode(): Int = bytes.contentHashCode()
        }
        /** A host-supplied SoundFont Uri, used verbatim. */
        data class ExistingUri(val uri: Uri) : Resolution
        /** Fall back to the score's GM drum-kit lookup. */
        object DefaultGm : Resolution
    }

    fun resolve(): Resolution =
        when (val source = provider?.metronomeClickSource() ?: MetronomeClickSource.DefaultGm) {
            is MetronomeClickSource.ClickSamples -> {
                val sf2 = jniBridge.buildClickSoundFont(source.strongWav, source.weakWav)
                if (sf2.isEmpty()) Resolution.DefaultGm else Resolution.GeneratedSf2(sf2)
            }
            is MetronomeClickSource.SoundFont -> Resolution.ExistingUri(source.uri)
            MetronomeClickSource.DefaultGm -> Resolution.DefaultGm
        }
}

/**
 * Loads a resolved metronome SoundFont onto a [SynthDriver]. Separated from
 * the resolver because it touches [Context] / [Uri] / the filesystem (not
 * JVM-unit-testable). Verified on-device.
 */
internal object MetronomeSf2Loader {
    fun load(
        synth: SynthDriver,
        resolution: AndroidMetronomeClickResolver.Resolution,
        soundfontResolver: SoundfontResolver,
        context: Context?,
    ) {
        when (resolution) {
            is AndroidMetronomeClickResolver.Resolution.GeneratedSf2 -> {
                val uri = writeToCache(resolution.bytes, context) ?: return
                synth.loadSoundFont(uri, context)
            }
            is AndroidMetronomeClickResolver.Resolution.ExistingUri ->
                synth.loadSoundFont(resolution.uri, context)
            AndroidMetronomeClickResolver.Resolution.DefaultGm -> {
                val uri = soundfontResolver.soundfontUriFor(0, 0, isDrums = true)
                    ?: soundfontResolver.defaultGmSoundfontUri
                uri?.let { synth.loadSoundFont(it, context) }
            }
        }
    }

    /** Content-addressed cache file so identical clicks reuse one file. */
    private fun writeToCache(bytes: ByteArray, context: Context?): Uri? {
        val ctx = context ?: return null
        return try {
            val dir = File(ctx.cacheDir, "metronome-clicks").apply { mkdirs() }
            val file = File(dir, "click-${bytes.contentHashCode().toUInt().toString(16)}.sf2")
            if (!file.exists() || file.length() == 0L) {
                file.outputStream().use { it.write(bytes) }
            }
            Uri.fromFile(file)
        } catch (e: Exception) {
            null
        }
    }
}
