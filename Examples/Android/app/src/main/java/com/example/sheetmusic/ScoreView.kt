package com.example.sheetmusic

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.example.sheetmusic.audio.AudioControls
import com.example.sheetmusic.audio.AudioViewModel
import com.example.sheetmusic.audio.MixerPanel

@Composable
fun ScoreView(
    state: ScoreState.Ready,
    onPageChange: (Int) -> Unit,
    audioVm: AudioViewModel,
) {
    Column(Modifier.fillMaxSize()) {
        PageControls(state, onPageChange)
        // Score canvas fills available space; pan/zoom gesture captured here.
        // Tap-to-seek: ScoreCanvas does not yet expose tap → ScoreCursor mapping.
        // When that mapping is implemented (future phase), wire it as:
        //   onTapCursor = { cursor -> audioVm.engine.seek(cursor) }
        ScoreCanvas(
            state,
            modifier = Modifier.fillMaxWidth().weight(1f)
        )
        AudioControls(audioVm)
        MixerPanel(audioVm)
    }
}
