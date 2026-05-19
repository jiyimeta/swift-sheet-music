package com.example.sheetmusic

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun PageControls(state: ScoreState.Ready, onPageChange: (Int) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        TextButton(
            onClick = { onPageChange(state.currentPage - 1) },
            enabled = state.currentPage > 0
        ) { Text("Prev") }

        Text("${state.currentPage + 1} / ${state.pageCount}")

        TextButton(
            onClick = { onPageChange(state.currentPage + 1) },
            enabled = state.currentPage < state.pageCount - 1
        ) { Text("Next") }
    }
}
