package com.example.sheetmusic

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import androidx.compose.ui.platform.LocalContext
import com.example.sheetmusic.draw.DrawCommand
import com.example.sheetmusic.draw.DrawPage

private const val FONT_ID_TEXT_ROMAN = 0
private const val FONT_ID_SMUFL = 1

@Composable
fun ScoreCanvas(state: ScoreState.Ready, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val bravura = remember(context) {
        Typeface.createFromAsset(context.assets, "fonts/Bravura.otf")
    }
    val edwin = remember(context) {
        Typeface.createFromAsset(context.assets, "fonts/Edwin-Roman.otf")
    }
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val page = state.program.pages[state.currentPage]
    Canvas(
        modifier = modifier
            .fillMaxSize()
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    scale = (scale * zoom).coerceIn(0.25f, 8f)
                    offset += pan
                }
            }
    ) {
        val pxPerMM = pxPerMM(canvasSizeMM = page.widthMM)
        withTransform({
            translate(offset.x, offset.y)
            scale(scale, scale, pivot = Offset.Zero)
        }) {
            drawPage(page, pxPerMM, bravura, edwin)
        }
    }
}

private fun DrawScope.pxPerMM(canvasSizeMM: Double): Float =
    (size.width / canvasSizeMM).toFloat()

private fun DrawScope.drawPage(
    page: DrawPage,
    pxPerMM: Float,
    bravura: Typeface,
    edwin: Typeface
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
                path.lineTo(cmd.x.toFloat() * pxPerMM,
                            cmd.y.toFloat() * pxPerMM)
            }
            is DrawCommand.Stroke -> {
                val widthPx = (cmd.width.toFloat() * pxPerMM)
                    .coerceAtLeast(1.5f)
                drawPath(
                    path = path,
                    color = Color(currentArgb),
                    style = Stroke(width = widthPx)
                )
                path.reset()
                strokeStarted = false
            }
            is DrawCommand.FillRect -> {
                drawRect(
                    color = Color(currentArgb),
                    topLeft = Offset(cmd.x.toFloat() * pxPerMM,
                                     cmd.y.toFloat() * pxPerMM),
                    size = Size(cmd.w.toFloat() * pxPerMM,
                                cmd.h.toFloat() * pxPerMM)
                )
            }
            is DrawCommand.Glyph -> {
                glyphPaint.typeface =
                    if (cmd.fontId == FONT_ID_SMUFL) bravura else edwin
                glyphPaint.textSize = cmd.size.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                val s = codepointToString(cmd.codepoint.toInt())
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        s,
                        cmd.x.toFloat() * pxPerMM,
                        cmd.y.toFloat() * pxPerMM,
                        glyphPaint
                    )
                }
            }
            is DrawCommand.Text -> {
                glyphPaint.typeface =
                    if (cmd.fontId == FONT_ID_SMUFL) bravura else edwin
                glyphPaint.textSize = cmd.size.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        cmd.text,
                        cmd.x.toFloat() * pxPerMM,
                        cmd.y.toFloat() * pxPerMM,
                        glyphPaint
                    )
                }
            }
            is DrawCommand.SetColor -> {
                currentArgb = cmd.argb.toInt()
            }
        }
    }
}

private fun codepointToString(cp: Int): String =
    String(intArrayOf(cp), 0, 1)
