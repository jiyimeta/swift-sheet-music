package com.example.sheetmusic.cursor

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.withTransform
import com.example.sheetmusic.jni.SheetMusicBridge
import io.github.kiichiio.sheetmusic.audio.model.LoopRange
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest

/**
 * Translucent rectangle overlay highlighting the active loop region.
 *
 * Sits in the same Box as ScoreCanvas + PlaybackCursorOverlay and
 * uses identical transform parameters so a multi-system loop region
 * lines up under the score columns. Observes the engine's
 * [loopRangeFlow]; clears its highlight when null.
 *
 * @param scoreHandle       opaque handle from ScoreViewModel.scoreHandle
 * @param loopRangeFlow     StateFlow<LoopRange?> from AudioViewModel.loopRange
 * @param pxPerMM           pixels per document-millimetre
 * @param scale             pan/zoom scale factor
 * @param panOffset         pan translation
 * @param color             fill color
 * @param modifier          must match ScoreCanvas' modifier
 */
@Composable
fun LoopHighlightOverlay(
    scoreHandle: Long,
    loopRangeFlow: StateFlow<LoopRange?>,
    pxPerMM: Float,
    scale: Float,
    panOffset: Offset,
    color: Color = Color(0x44_FF_CC_33.toInt()), // semi-transparent amber
    modifier: Modifier = Modifier,
) {
    var frames by remember { mutableStateOf<List<LoopHighlightFrame>>(emptyList()) }

    LaunchedEffect(scoreHandle, loopRangeFlow) {
        loopRangeFlow.collectLatest { lr ->
            frames = if (lr == null) {
                emptyList()
            } else {
                val bytes = SheetMusicBridge.nativeLoopHighlightRects(
                    scoreHandle,
                    lr.startTick,
                    lr.endTick,
                )
                LoopHighlightFrameCodec.decode(bytes)
            }
        }
    }

    if (frames.isEmpty()) return

    Canvas(modifier = modifier) {
        withTransform({
            translate(panOffset.x, panOffset.y)
            scale(scale, scale, pivot = Offset.Zero)
        }) {
            for (f in frames) {
                drawRect(
                    color = color,
                    topLeft = Offset(
                        x = f.x.toFloat() * pxPerMM,
                        y = f.y.toFloat() * pxPerMM,
                    ),
                    size = Size(
                        width = f.width.toFloat() * pxPerMM,
                        height = f.height.toFloat() * pxPerMM,
                    ),
                )
            }
        }
    }
}
