package io.github.jiyimeta.sheetmusic.compose.render

import android.graphics.Canvas
import android.graphics.RectF
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand
import androidx.compose.ui.graphics.Canvas as ComposeCanvas

/**
 * Replays [commands] onto this canvas, outside Compose: document millimetre (x, y) lands at pixel
 * (originXPx + x·pxPerMM, originYPx + y·pxPerMM); [clipPx] (canvas pixels, before the origin shift) bounds the ink;
 * the canvas's save stack is restored on return. [styledText] draws bold / italic runs in real faces instead of
 * synthesizing them from the text face — pass it when the layout was measured with a styled table.
 *
 * The same renderer as [ScoreCanvas], [ScorePage] and the PDF exporter, so a picture drawn here — a video frame on a
 * Bitmap, a PDF page — carries exactly the ink the screen does. Only ink is painted: the caller fills the background.
 */
fun Canvas.drawScoreCommands(
    commands: List<DrawCommand>,
    pxPerMM: Float,
    fontProvider: FontProvider,
    originXPx: Float = 0f,
    originYPx: Float = 0f,
    clipPx: RectF? = null,
    styledText: StyledTextTypefaces? = null,
) {
    val saveCount = save()
    try {
        if (clipPx != null) clipRect(clipPx)
        translate(originXPx, originYPx)
        CanvasDrawScope().draw(
            density = Density(density = 1f, fontScale = 1f),
            layoutDirection = LayoutDirection.Ltr,
            canvas = ComposeCanvas(this),
            size = Size(width.toFloat(), height.toFloat()),
        ) {
            drawCommands(
                commands = commands,
                pxPerMM = pxPerMM,
                smufl = fontProvider.smuflTypeface(),
                text = fontProvider.textTypeface(),
                styled = styledText,
            )
        }
    } finally {
        // Also when a command throws: the canvas belongs to the caller, who may draw more into it.
        restoreToCount(saveCount)
    }
}
