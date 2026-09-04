package io.github.jiyimeta.sheetmusic.compose.render

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.dp
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.compose.draw.DrawProgramReader
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage

/**
 * MuseScore's `invisibleColor()` — `#808080`, which on white is 50% black.
 *
 * The frozen elements are drawn at half opacity to say they are a restatement
 * rather than notation at this position; `continuouspanel.cpp:417` picks the
 * same value, and `StickyHeaderView` applies it the same way on Apple.
 */
private const val FROZEN_OPACITY = 0.5f

/**
 * The frozen clef / key / time / instrument-name pane for a horizontal
 * continuous view, pinned at the viewport's left edge.
 *
 * A reader who has scrolled past bar 1 otherwise has no way to see what key and
 * metre they are in without scrolling back. MuseScore's continuous view solves
 * it this way and so does `SheetMusicUI.StickyHeaderView`; this is the same pane
 * for Compose hosts.
 *
 * Place it as a fixed overlay at the viewport's left edge — for example inside a
 * `Box` with `Alignment.TopStart` over the scrolling score — and clip beyond the
 * reported width so the music scrolls independently underneath it.
 *
 * The pane is engraved by the shared Swift layout engine and arrives as an
 * ordinary one-page draw program, so it is painted by [drawCommands], the same
 * renderer the score itself goes through.
 *
 * @param scoreHandle the score's native handle. Its layout must already have
 *   been computed — the pane is derived from the cached document.
 * @param documentScrollXMm the viewport's left edge in document millimetres.
 * @param pxPerMM pixels per document millimetre; pass the value `ScoreCanvas`
 *   reports so the pane and the score are drawn at one scale.
 */
@Composable
fun StickyHeaderPane(
    scoreHandle: Long,
    documentScrollXMm: Double,
    pxPerMM: Float,
    fontProvider: FontProvider,
    modifier: Modifier = Modifier,
) {
    // Keyed on the measure the scroll position lands in, not on the position: a
    // pane is only re-engraved when the frozen state actually changes, so a
    // smooth scroll across one bar costs one JNI round trip rather than one per
    // frame. The bridge is what knows where the bar boundaries are, so the key
    // is the scroll position rounded to the nearest millimetre — coarse enough
    // to collapse a frame-by-frame scroll, fine enough never to skip a bar.
    val page: EncodablePage? = remember(scoreHandle, documentScrollXMm.toLong()) {
        val bytes = SheetMusicJNI.nativeStickyHeaderProgram(scoreHandle, documentScrollXMm)
        if (bytes.isEmpty()) null else DrawProgramReader.decode(bytes).pages.firstOrNull()
    }
    if (page == null) return

    val smufl = fontProvider.smuflTypeface()
    val text = fontProvider.textTypeface()
    Canvas(
        modifier = modifier.size(
            width = (page.widthMM * pxPerMM).dp,
            height = (page.heightMM * pxPerMM).dp,
        ),
    ) {
        // Opaque white behind the pane: it sits OVER the scrolling score, and a
        // transparent one would show the music running underneath the frozen
        // clef.
        drawRect(Color.White, size = size)
        drawFrozen(page, pxPerMM, smufl, text)
    }
}

private fun DrawScope.drawFrozen(
    page: EncodablePage,
    pxPerMM: Float,
    smufl: android.graphics.Typeface,
    text: android.graphics.Typeface,
) {
    // `alpha` on the layer rather than per command: the draw program sets its own
    // colours (a coloured element keeps its colour), and multiplying each one
    // would be a second colour rule for the renderer to get wrong.
    drawContext.canvas.saveLayer(
        androidx.compose.ui.geometry.Rect(0f, 0f, size.width, size.height),
        androidx.compose.ui.graphics.Paint().apply { alpha = FROZEN_OPACITY },
    )
    drawCommands(page.commands, pxPerMM, smufl, text)
    drawContext.canvas.restore()
}
