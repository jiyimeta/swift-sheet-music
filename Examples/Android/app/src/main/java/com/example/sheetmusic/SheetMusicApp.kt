package com.example.sheetmusic

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

@Composable
fun SheetMusicApp(viewModel: ScoreViewModel = viewModel()) {
    val state by viewModel.state.collectAsState()
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize(), color = Color.White) {
            when (val s = state) {
                ScoreState.Loading -> CenteredMessage("Loading …")
                ScoreState.MissingFixture -> MissingFixtureMessage()
                is ScoreState.ParseError -> CenteredMessage("Error: ${s.message}")
                is ScoreState.Ready -> ScoreView(
                    state = s,
                    onPageChange = viewModel::goToPage
                )
            }
        }
    }
}

@Composable
private fun CenteredMessage(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text)
    }
}

@Composable
private fun MissingFixtureMessage() {
    Box(
        Modifier.fillMaxSize().background(Color.White).padding(24.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            "test.mscz is not bundled.\n\n" +
            "Place a MuseScore file at:\n" +
            "  ~/Desktop/test.mscz\n\n" +
            "Then run:\n" +
            "  Scripts/android-bundle-test-score.sh\n\n" +
            "and rebuild the app.",
            style = MaterialTheme.typography.bodyLarge
        )
    }
}
