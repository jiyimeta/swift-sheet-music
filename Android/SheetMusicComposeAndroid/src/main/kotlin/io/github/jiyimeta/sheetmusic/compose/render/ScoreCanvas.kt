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
import androidx.compose.ui.graphics.PathEffect
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

/**
 * Gesture-free renderer for a single [EncodablePage]. Unlike [ScoreCanvas],
 * this installs no pan/zoom pointer input and applies no translate — the
 * caller is expected to host it inside a native scroll container (which owns
 * scroll bounds, fling, and overscroll) and to bake zoom into [pxPerMM]
 * (`fitPxPerMM * scale`). Drawing at the zoomed [pxPerMM] re-rasterizes glyphs
 * at the target resolution, so the score stays sharp at every zoom level.
 *
 * @param page          the page to draw (document coordinates in mm)
 * @param fontProvider  supplies the SMuFL + text typefaces
 * @param pxPerMM       pixels per document-millimetre, already including zoom
 * @param modifier      should size the canvas to the zoomed content extent
 */
@Composable
fun ScorePage(
    page: EncodablePage,
    fontProvider: FontProvider,
    pxPerMM: Float,
    modifier: Modifier = Modifier,
) {
    val smufl = fontProvider.smuflTypeface()
    val text = fontProvider.textTypeface()
    Canvas(modifier = modifier) {
        drawPage(page, pxPerMM, smufl, text)
    }
}

private fun DrawScope.drawPage(
    page: EncodablePage,
    pxPerMM: Float,
    smufl: android.graphics.Typeface,
    text: android.graphics.Typeface,
) = drawCommands(page.commands, pxPerMM, smufl, text)

/**
 * Paint one command run. Split out of [drawPage] so a band ([ScoreBand]) — a self-contained slice of a
 * page's commands, still in page coordinates — can be drawn by the same renderer under a translate.
 */
internal fun DrawScope.drawCommands(
    commands: List<DrawCommand>,
    pxPerMM: Float,
    smufl: android.graphics.Typeface,
    text: android.graphics.Typeface,
) {
    val path = Path()
    var strokeStarted = false
    var currentArgb: Int = android.graphics.Color.BLACK
    // State commands accumulate here. `dash*` gates the stroke path effect;
    // `rotationSaveCount` tracks the native-canvas save depth for an active
    // SetRotation so the paired `SetRotation(0)` can restore it.
    var dashOnPx = 0f
    var dashOffPx = 0f
    var rotationSaveCount = -1
    val glyphPaint = Paint().apply {
        isAntiAlias = true
        color = currentArgb
    }
    for (cmd in commands) {
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
                val effect = if (dashOnPx > 0f && dashOffPx > 0f) {
                    PathEffect.dashPathEffect(floatArrayOf(dashOnPx, dashOffPx), 0f)
                } else {
                    null
                }
                drawPath(
                    path = path,
                    color = Color(currentArgb),
                    style = Stroke(width = widthPx, pathEffect = effect),
                )
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
            is DrawCommand.StretchedGlyph -> {
                glyphPaint.typeface = if (cmd.fontId == FontID.SMUFL) smufl else text
                glyphPaint.textSize = cmd.fontSize.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                val s = String(intArrayOf(cmd.codepoint.toInt()), 0, 1)
                val bounds = android.graphics.Rect()
                glyphPaint.getTextBounds(s, 0, s.length, bounds)
                if (bounds.width() > 0 && bounds.height() > 0) {
                    val rightEdgePx = cmd.rightEdgeX.toFloat() * pxPerMM
                    val topPx = cmd.topY.toFloat() * pxPerMM
                    val bottomPx = cmd.bottomY.toFloat() * pxPerMM
                    val xScale = cmd.xScale.toFloat()
                    val scaleY = (bottomPx - topPx) / bounds.height()
                    drawIntoCanvas { canvas ->
                        val native = canvas.nativeCanvas
                        val save = native.save()
                        // Place the scaled glyph bbox: right edge at rightEdgePx,
                        // top at topPx — mirrors iOS smuflGlyphPathStretched.
                        // translate-then-scale maps a glyph point p to
                        // (tx + sx*px, ty + sy*py).
                        native.translate(
                            rightEdgePx - xScale * bounds.right,
                            topPx - scaleY * bounds.top,
                        )
                        native.scale(xScale, scaleY)
                        native.drawText(s, 0f, 0f, glyphPaint)
                        native.restoreToCount(save)
                    }
                }
            }
            is DrawCommand.SetColor -> {
                currentArgb = cmd.argb.toInt()
            }
            is DrawCommand.SetRotation -> {
                drawIntoCanvas { canvas ->
                    val native = canvas.nativeCanvas
                    if (cmd.radians != 0.0) {
                        rotationSaveCount = native.save()
                        native.rotate(
                            Math.toDegrees(cmd.radians).toFloat(),
                            cmd.pivotX.toFloat() * pxPerMM,
                            cmd.pivotY.toFloat() * pxPerMM,
                        )
                    } else if (rotationSaveCount >= 0) {
                        native.restoreToCount(rotationSaveCount)
                        rotationSaveCount = -1
                    }
                }
            }
            is DrawCommand.SetDash -> {
                dashOnPx = cmd.onMM.toFloat() * pxPerMM
                dashOffPx = cmd.offMM.toFloat() * pxPerMM
            }
            is DrawCommand.ItalicText -> {
                glyphPaint.typeface = if (cmd.fontId == FontID.SMUFL) smufl else text
                glyphPaint.textSize = cmd.size.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                glyphPaint.textSkewX = -0.25f
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        cmd.text, cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM, glyphPaint,
                    )
                }
                glyphPaint.textSkewX = 0f
            }
        }
    }
}
