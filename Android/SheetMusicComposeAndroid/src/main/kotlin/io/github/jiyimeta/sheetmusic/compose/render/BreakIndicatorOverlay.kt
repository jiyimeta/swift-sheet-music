package io.github.jiyimeta.sheetmusic.compose.render

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import io.github.jiyimeta.sheetmusic.BreakIndicatorWire
import io.github.jiyimeta.sheetmusic.BreakIndicatorsWireCodec
import io.github.jiyimeta.sheetmusic.SheetMusicJNI

/** `kind` values in `BreakIndicatorWire`. Mirrors the Swift bridge's own numbering. */
private const val KIND_LINE = 0

/** Badge size in PIXELS, not millimetres — see [BreakIndicatorOverlay]. */
private const val BADGE_WIDTH_PX = 16f
private const val BADGE_HEIGHT_PX = 12f
private const val BADGE_CORNER_PX = 2.5f

private val LINE_BREAK_COLOR = Color(0xFF3B7DD8)
private val PAGE_BREAK_COLOR = Color(0xFFD8733B)

/**
 * MuseScore-style badges over the measures that carry an explicit
 * `<LayoutBreak>`, so an author can see where the file forces a system or page
 * to end.
 *
 * Ask for them through `LayoutOptionsWire.breakIndicatorVisibilityRaw` when
 * computing the layout — `0` none (the default), `1` page breaks only, `2` all.
 * The bridge applies the break *policy* first, so a badge never appears for a
 * break the current layout is ignoring.
 *
 * Draw it as an overlay on the same `Box` as the score, sharing the canvas's
 * `pxPerMM` and pan/zoom, exactly like the playback cursor.
 *
 * **The badge does not scale with the staff.** It is an authoring hint about the
 * file rather than notation, and a hint that shrinks with the music becomes
 * unreadable exactly when the score is zoomed out to look at its breaks — which
 * is the view an author checking breaks is in. Only the badge's POSITION is in
 * document space. `SheetMusicUI.BreakIndicatorOverlay` makes the same choice on
 * Apple, at the same 16×12 size.
 *
 * Never hit-testable: it sits over the score and must not swallow taps meant for
 * the notation underneath.
 *
 * @param scoreHandle the score's native handle; its layout must already be computed.
 * @param pxPerMM pixels per document millimetre, as `ScoreCanvas` reports it.
 * @param transform the canvas's current pan/zoom, so badges track the score.
 */
@Composable
fun BreakIndicatorOverlay(
    scoreHandle: Long,
    pxPerMM: Float,
    transform: ScoreTransform = ScoreTransform(),
    modifier: Modifier = Modifier,
) {
    // Keyed on the handle alone: the badge set is a property of the laid-out
    // score, so it changes when the layout is recomputed (which replaces the
    // handle's cached document) and never in between. Re-reading it per frame
    // would be a JNI round trip for an answer that cannot have changed.
    val indicators: List<BreakIndicatorWire> = remember(scoreHandle) {
        val bytes = SheetMusicJNI.nativeBreakIndicators(scoreHandle)
        if (bytes.isEmpty()) {
            emptyList()
        } else {
            BreakIndicatorsWireCodec.decode(bytes).indicators
        }
    }
    if (indicators.isEmpty()) return

    Canvas(modifier = modifier.fillMaxSize()) {
        for (indicator in indicators) {
            drawBadge(
                indicator = indicator,
                pxPerMM = pxPerMM,
                transform = transform,
            )
        }
    }
}

private fun DrawScope.drawBadge(
    indicator: BreakIndicatorWire,
    pxPerMM: Float,
    transform: ScoreTransform,
) {
    // Position through the score's transform; size deliberately outside it.
    val centreX = indicator.xMm.toFloat() * pxPerMM * transform.scale + transform.panOffset.x
    val centreY = indicator.yMm.toFloat() * pxPerMM * transform.scale + transform.panOffset.y
    val topLeft = Offset(centreX - BADGE_WIDTH_PX / 2, centreY - BADGE_HEIGHT_PX / 2)
    val size = Size(BADGE_WIDTH_PX, BADGE_HEIGHT_PX)
    val isLine = indicator.kind == KIND_LINE

    drawRoundRect(
        color = if (isLine) LINE_BREAK_COLOR else PAGE_BREAK_COLOR,
        topLeft = topLeft,
        size = size,
        cornerRadius = CornerRadius(BADGE_CORNER_PX, BADGE_CORNER_PX),
    )

    // A glyph rather than an icon font: two badges is not worth a dependency, and
    // an SF-Symbol-shaped mark would not be available here anyway. A line break
    // gets a return arrow (one stroke down, one across); a page break gets a
    // horizontal rule, the same visual distinction the Apple badges make.
    val inset = 3.5f
    val stroke = Stroke(width = 1.5f)
    if (isLine) {
        drawLine(
            color = Color.White,
            start = Offset(topLeft.x + size.width - inset, topLeft.y + inset),
            end = Offset(topLeft.x + size.width - inset, centreY),
            strokeWidth = stroke.width,
        )
        drawLine(
            color = Color.White,
            start = Offset(topLeft.x + size.width - inset, centreY),
            end = Offset(topLeft.x + inset, centreY),
            strokeWidth = stroke.width,
        )
    } else {
        drawLine(
            color = Color.White,
            start = Offset(topLeft.x + inset, centreY),
            end = Offset(topLeft.x + size.width - inset, centreY),
            strokeWidth = stroke.width,
        )
    }
}
