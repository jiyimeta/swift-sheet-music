package io.github.jiyimeta.sheetmusic.compose.cursor

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
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest

/**
 * Translucent rectangle overlay that tracks the audio engine's playback cursor.
 *
 * Integration strategy (A): this composable is placed inside the same parent
 * Box as ScoreCanvas and sized with the same Modifier (fillMaxWidth + weight).
 * The caller passes the same [scale] and [panOffset] that ScoreCanvas uses
 * internally, so the overlay applies an identical withTransform{} and maps
 * document-coordinate rectangles to screen pixels without knowing the
 * canvas pixel size.
 *
 * Document coordinates are in the same mm unit space as the DrawProgram pages.
 * [pxPerMM] is derived from canvas width / page widthMM inside ScoreCanvas;
 * the overlay receives it as a Float so it can apply the same scaling factor.
 *
 * @param scoreHandle      opaque handle from ScoreViewModel.scoreHandle
 * @param cursorFlow       StateFlow<ScoreCursor?> from AudioViewModel.currentCursor
 * @param pxPerMM          pixels per document-millimetre (canvas width / page.widthMM)
 * @param scale            pan/zoom scale factor (same state as ScoreCanvas)
 * @param panOffset        pan translation (same state as ScoreCanvas)
 * @param color            fill color for the cursor highlight rectangle
 * @param modifier         must match ScoreCanvas modifier so the overlay is co-located
 */
@Composable
fun PlaybackCursorOverlay(
    scoreHandle: Long,
    cursorFlow: StateFlow<ScoreCursor?>,
    pxPerMM: Float,
    scale: Float,
    panOffset: Offset,
    color: Color = Color(0x33_3D_8E_FF.toInt()), // semi-transparent MuseScore blue
    modifier: Modifier = Modifier,
) {
    var frame by remember { mutableStateOf<CursorFrame?>(null) }

    LaunchedEffect(scoreHandle, cursorFlow) {
        cursorFlow.collectLatest { cursor ->
            frame = if (cursor == null) {
                null
            } else {
                val bytes = SheetMusicJNI.nativeCursorFrame(
                    scoreHandle,
                    ScoreCursorCodec.encode(cursor),
                )
                CursorFrame.decode(bytes)
            }
        }
    }

    val f = frame ?: return

    Canvas(modifier = modifier) {
        withTransform({
            translate(panOffset.x, panOffset.y)
            scale(scale, scale, pivot = Offset.Zero)
        }) {
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
