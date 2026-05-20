package com.example.sheetmusic.audio

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

@Composable
fun LoopSelectionOverlay(
    viewModel: AudioViewModel,
    modifier: Modifier = Modifier,
) {
    val lr by viewModel.loopRange.collectAsState()
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .background(if (lr != null) Color(0x222196F3) else Color.Transparent),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = if (lr != null) "Loop: ${lr!!.startTick}..${lr!!.endTick}"
                   else "Loop: off",
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = lr != null,
            enabled = lr != null,
            onCheckedChange = { on ->
                if (!on) viewModel.engine.clearLoop()
                // Setting a loop region requires a UI gesture not yet wired
                // (tap-to-set-A / -B). Phase 5.1 follow-up.
            },
        )
    }
}
