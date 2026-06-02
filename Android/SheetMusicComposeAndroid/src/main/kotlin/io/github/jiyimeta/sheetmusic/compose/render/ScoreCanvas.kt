package io.github.jiyimeta.sheetmusic.compose.render

import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import io.github.jiyimeta.sheetmusic.compose.draw.model.FontID

/** Pan/zoom transform shared between [ScoreCanvas] and the cursor overlays. */
data class ScoreTransform(
    val scale: Float = 1f,
    val panOffset: Offset = Offset.Zero,
)

/**
 * Renders a single [EncodablePage] of a draw program onto a Compose
 * [Canvas], with pinch-zoom + pan gesture handling.
 *
 * @param page          the page to draw (document coordinates in mm)
 * @param fontProvider  supplies the SMuFL + text typefaces
 * @param transform     current pan/zoom (hoisted so overlays can share it)
 * @param onTransformChange invoked on gesture
 * @param onPxPerMMChange reports pixels-per-mm so overlays can map mm -> px
 */
@Composable
fun ScoreCanvas(
    page: EncodablePage,
    fontProvider: FontProvider,
    transform: ScoreTransform,
    onTransformChange: (ScoreTransform) -> Unit,
    onPxPerMMChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    val currentTransform by rememberUpdatedState(transform)
    val currentOnTransformChange by rememberUpdatedState(onTransformChange)
    val smufl = fontProvider.smuflTypeface()
    val text = fontProvider.textTypeface()
    Canvas(
        modifier = modifier
            .fillMaxSize()
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    val t = currentTransform
                    currentOnTransformChange(
                        t.copy(
                            scale = (t.scale * zoom).coerceIn(0.25f, 8f),
                            panOffset = t.panOffset + pan,
                        )
                    )
                }
            }
    ) {
        val pxPerMM = (size.width / page.widthMM).toFloat()
        onPxPerMMChange(pxPerMM)
        withTransform({
            translate(transform.panOffset.x, transform.panOffset.y)
            scale(transform.scale, transform.scale, pivot = Offset.Zero)
        }) {
            drawPage(page, pxPerMM, smufl, text)
        }
    }
}

private fun DrawScope.drawPage(
    page: EncodablePage,
    pxPerMM: Float,
    smufl: android.graphics.Typeface,
    text: android.graphics.Typeface,
) {
    val path = Path()
    var strokeStarted = false
    var currentArgb: Int = android.graphics.Color.BLACK
    val glyphPaint = Paint().apply {
        isAntiAlias = true
        color = currentArgb
    }
    for (cmd in page.commands) {
        when (cmd) {
            is DrawCommand.MoveTo -> {
                val x = cmd.x.toFloat() * pxPerMM
                val y = cmd.y.toFloat() * pxPerMM
                if (strokeStarted) path.reset()
                path.moveTo(x, y)
                strokeStarted = true
            }
            is DrawCommand.LineTo -> {
                path.lineTo(cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM)
            }
            is DrawCommand.CubicTo -> {
                path.cubicTo(
                    cmd.cx1.toFloat() * pxPerMM,
                    cmd.cy1.toFloat() * pxPerMM,
                    cmd.cx2.toFloat() * pxPerMM,
                    cmd.cy2.toFloat() * pxPerMM,
                    cmd.x.toFloat() * pxPerMM,
                    cmd.y.toFloat() * pxPerMM,
                )
            }
            is DrawCommand.Stroke -> {
                val widthPx = (cmd.width.toFloat() * pxPerMM).coerceAtLeast(1.5f)
                drawPath(path = path, color = Color(currentArgb), style = Stroke(width = widthPx))
                path.reset()
                strokeStarted = false
            }
            is DrawCommand.FillRect -> {
                drawRect(
                    color = Color(currentArgb),
                    topLeft = Offset(cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM),
                    size = Size(cmd.w.toFloat() * pxPerMM, cmd.h.toFloat() * pxPerMM),
                )
            }
            is DrawCommand.Glyph -> {
                glyphPaint.typeface = if (cmd.fontId == FontID.SMUFL) smufl else text
                glyphPaint.textSize = cmd.size.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                val s = String(intArrayOf(cmd.codepoint.toInt()), 0, 1)
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        s, cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM, glyphPaint,
                    )
                }
            }
            is DrawCommand.Text -> {
                glyphPaint.typeface = if (cmd.fontId == FontID.SMUFL) smufl else text
                glyphPaint.textSize = cmd.size.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        cmd.text, cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM, glyphPaint,
                    )
                }
            }
            is DrawCommand.SetColor -> {
                currentArgb = cmd.argb.toInt()
            }
        }
    }
}
