package com.example.sheetmusic

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

@Composable
fun ScoreView(state: ScoreState.Ready, onPageChange: (Int) -> Unit) {
    Column(Modifier.fillMaxSize()) {
        PageControls(state, onPageChange)
        ScoreCanvas(
            state,
            modifier = Modifier.fillMaxWidth().weight(1f)
        )
    }
}
