package com.example.sheetmusic

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

@Composable
fun ScoreView(state: ScoreState.Ready, onPageChange: (Int) -> Unit) {
    Box(Modifier.fillMaxSize()) {
        ScoreCanvas(state)
        PageControls(state, onPageChange)
    }
}
