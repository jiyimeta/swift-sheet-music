package io.github.jiyimeta.sheetmusic.compose.render

import android.content.Context
import android.graphics.Typeface

/**
 * Supplies the two typefaces the score renderer draws with:
 * a SMuFL music font (Bravura) and a text font (Edwin).
 *
 * The library ships both fonts as assets and provides
 * [bundledFontProvider]; consumers may pass their own implementation
 * to [ScoreCanvas] to override.
 */
interface FontProvider {
    /** SMuFL music glyph font (Bravura). */
    fun smuflTypeface(): Typeface

    /** Text/lyric font (Edwin). */
    fun textTypeface(): Typeface
}

/**
 * [FontProvider] backed by the fonts bundled in this library's assets.
 * Typefaces are created once and cached.
 */
fun bundledFontProvider(context: Context): FontProvider {
    val appContext = context.applicationContext
    return object : FontProvider {
        private val bravura: Typeface by lazy {
            Typeface.createFromAsset(appContext.assets, "fonts/Bravura.otf")
        }
        private val edwin: Typeface by lazy {
            Typeface.createFromAsset(appContext.assets, "fonts/Edwin-Roman.otf")
        }

        override fun smuflTypeface(): Typeface = bravura
        override fun textTypeface(): Typeface = edwin
    }
}
