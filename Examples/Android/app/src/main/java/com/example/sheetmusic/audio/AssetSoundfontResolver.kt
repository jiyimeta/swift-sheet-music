package com.example.sheetmusic.audio

import android.content.Context
import android.net.Uri
import androidx.core.net.toUri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import java.io.File

/**
 * Resolves the SoundFont URI by reading `gm.sf2` from the app's
 * assets/ directory, materializing it to internal storage on first use.
 *
 * Both per-staff and metronome lookups return the same SF2 in v0 — the
 * bundled General MIDI SoundFont covers melodic and drum presets.
 *
 * If `gm.sf2` is absent from assets, [soundfontUriFor] and
 * [defaultGmSoundfontUri] return `null`. [AndroidPlaybackEngine.prepare]
 * will then skip SoundFont loading; the engine initializes but produces
 * silence. A follow-up should surface a "No SoundFont" warning in the UI.
 *
 * To supply the SoundFont:
 *   1. Place `gm.sf2` at `~/Desktop/gm.sf2`
 *   2. Run `Scripts/android-bundle-test-score.sh`
 *   3. Rebuild the app
 */
class AssetSoundfontResolver(private val context: Context) : SoundfontResolver {

    private val cachedFile: File? by lazy {
        try {
            val out = File(context.cacheDir, "gm.sf2")
            if (!out.exists()) {
                context.assets.open("gm.sf2").use { input ->
                    out.outputStream().use { input.copyTo(it) }
                }
            }
            out
        } catch (_: Exception) {
            android.util.Log.w(
                "AssetSoundfontResolver",
                "gm.sf2 not found in assets — audio will be silent. " +
                    "Run Scripts/android-bundle-test-score.sh to install it."
            )
            null
        }
    }

    private val cachedUri: Uri? by lazy { cachedFile?.absoluteFile?.toUri() }

    override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = cachedUri
    override val defaultGmSoundfontUri: Uri? get() = cachedUri
}
