package io.github.jiyimeta.sheetmusic

import android.content.res.AssetManager

/**
 * Deprecated alias for [FontMetricsBuilder].
 *
 * The builder was renamed when the metrics table stopped being
 * Bravura-only — SMFT v4 carries the text face (Edwin) alongside the
 * SMuFL face, so a name saying "Bravura" had become wrong. The shape of
 * the call is unchanged, so hosts that still call this keep working.
 *
 * Removed in 3.0.0; call [FontMetricsBuilder] directly.
 */
@Deprecated(
    message = "Renamed to FontMetricsBuilder: the table carries the text face too.",
    replaceWith = ReplaceWith(
        "FontMetricsBuilder",
        "io.github.jiyimeta.sheetmusic.FontMetricsBuilder",
    ),
    level = DeprecationLevel.WARNING,
)
object BravuraMetricsBuilder {
    /**
     * Forwards to [FontMetricsBuilder.buildTable].
     *
     * The bytes returned are an SMFT **v4** table — the same one
     * [FontMetricsBuilder] produces — not the v3 layout that shipped under
     * this name through 2.4.x.
     */
    fun buildTable(assets: AssetManager): ByteArray =
        FontMetricsBuilder.buildTable(assets)
}
