package com.example.sheetmusic

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.example.sheetmusic.audio.AudioControls
import com.example.sheetmusic.audio.AudioViewModel
import com.example.sheetmusic.audio.MixerPanel
import com.example.sheetmusic.cursor.PlaybackCursorOverlay

@Composable
fun ScoreView(
    state: ScoreState.Ready,
    onPageChange: (Int) -> Unit,
    audioVm: AudioViewModel,
    scoreVm: ScoreViewModel,
) {
    // Pan/zoom transform — lifted here so PlaybackCursorOverlay can share it.
    var transform by remember { mutableStateOf(ScoreTransform()) }
    // pxPerMM is reported back from ScoreCanvas on each recomposition.
    var pxPerMM by remember { mutableFloatStateOf(1f) }

    val scoreHandle by scoreVm.scoreHandle.collectAsState()

    Column(Modifier.fillMaxSize()) {
        PageControls(state, onPageChange)
        // Score canvas + cursor overlay share the same Box so the overlay
        // sits on top with the same size modifier.
        Box(Modifier.fillMaxWidth().weight(1f)) {
            ScoreCanvas(
                state = state,
                transform = transform,
                onTransformChange = { transform = it },
                onPxPerMMChange = { pxPerMM = it },
                modifier = Modifier.fillMaxSize(),
            )
            val handle = scoreHandle
            if (handle != null) {
                PlaybackCursorOverlay(
                    scoreHandle = handle,
                    cursorFlow = audioVm.currentCursor,
                    pxPerMM = pxPerMM,
                    scale = transform.scale,
                    panOffset = transform.panOffset,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        AudioControls(audioVm)
        MixerPanel(audioVm)
    }
}
