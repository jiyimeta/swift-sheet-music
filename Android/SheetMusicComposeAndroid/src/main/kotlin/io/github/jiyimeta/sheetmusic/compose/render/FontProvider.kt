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

/**
 * Real bold, italic and bold-italic text faces, for drawing a layout measured with a metrics table whose styled
 * records measure them — the bundled `sheet-music-styled.smft`, the portable table Windows and Apple lay out with too.
 *
 * Without these the renderer synthesizes bold and italic from [FontProvider.textTypeface], which matches the table
 * `FontMetricsBuilder` builds on the device. Pair each table with its own faces: a run drawn in the other kind is
 * wider or narrower than the layout measured, and a right-aligned label or a rehearsal mark's frame lands off by the
 * difference.
 */
class StyledTextTypefaces(val bold: Typeface, val italic: Typeface, val boldItalic: Typeface)

/**
 * [StyledTextTypefaces] from this library's assets: `fonts/Edwin-Bold.otf`, `fonts/Edwin-Italic.otf` and
 * `fonts/Edwin-BdIta.otf`, the faces `sheet-music-styled.smft` measures. Each call loads all three, so make it once
 * and keep it.
 */
fun bundledStyledTextTypefaces(context: Context): StyledTextTypefaces {
    val assets = context.applicationContext.assets
    return StyledTextTypefaces(
        bold = Typeface.createFromAsset(assets, "fonts/Edwin-Bold.otf"),
        italic = Typeface.createFromAsset(assets, "fonts/Edwin-Italic.otf"),
        boldItalic = Typeface.createFromAsset(assets, "fonts/Edwin-BdIta.otf"),
    )
}
