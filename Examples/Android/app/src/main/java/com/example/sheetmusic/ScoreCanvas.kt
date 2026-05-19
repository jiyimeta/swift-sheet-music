package com.example.sheetmusic

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
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.pointer.pointerInput
import com.example.sheetmusic.draw.DrawCommand
import com.example.sheetmusic.draw.DrawPage

@Composable
fun ScoreCanvas(state: ScoreState.Ready) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val page = state.program.pages[state.currentPage]
    Canvas(
        modifier = Modifier
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
            drawPage(page, pxPerMM)
        }
    }
}

private fun DrawScope.pxPerMM(canvasSizeMM: Double): Float =
    (size.width / canvasSizeMM).toFloat()

private fun DrawScope.drawPage(page: DrawPage, pxPerMM: Float) {
    var current = Offset.Zero
    val path = Path()
    var strokeStarted = false
    for (cmd in page.commands) {
        when (cmd) {
            is DrawCommand.MoveTo -> {
                current = Offset(cmd.x.toFloat() * pxPerMM,
                                 cmd.y.toFloat() * pxPerMM)
                if (strokeStarted) { /* discard prior subpath */ path.reset() }
                path.moveTo(current.x, current.y)
                strokeStarted = true
            }
            is DrawCommand.LineTo -> {
                current = Offset(cmd.x.toFloat() * pxPerMM,
                                 cmd.y.toFloat() * pxPerMM)
                path.lineTo(current.x, current.y)
            }
            is DrawCommand.Stroke -> {
                drawPath(
                    path = path,
                    color = Color.Black,
                    style = Stroke(width = (cmd.width.toFloat() * pxPerMM)
                                         .coerceAtLeast(1f))
                )
                path.reset()
                strokeStarted = false
            }
            is DrawCommand.FillRect -> {
                drawRect(
                    color = Color.Black,
                    topLeft = Offset(cmd.x.toFloat() * pxPerMM,
                                     cmd.y.toFloat() * pxPerMM),
                    size = Size(cmd.w.toFloat() * pxPerMM,
                                cmd.h.toFloat() * pxPerMM)
                )
            }
            is DrawCommand.Glyph -> {
                // Phase 4 simplification: render glyphs as small filled
                // squares at the requested position. SMuFL font support is
                // an open question deferred to a follow-up task.
                val s = (cmd.size.toFloat() * pxPerMM) * 0.5f
                drawRect(
                    color = Color.Black,
                    topLeft = Offset(cmd.x.toFloat() * pxPerMM - s / 2,
                                     cmd.y.toFloat() * pxPerMM - s / 2),
                    size = Size(s, s)
                )
            }
            is DrawCommand.Text -> {
                // Same simplification — text rendering deferred. The
                // StubFontMetricsProvider already produces rectangle
                // approximations, so omitting text rendering here is
                // consistent with Phase 2's fidelity statement.
            }
        }
    }
}
