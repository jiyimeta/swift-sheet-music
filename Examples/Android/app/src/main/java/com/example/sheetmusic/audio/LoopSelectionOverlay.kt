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
import io.github.kiichiio.sheetmusic.audio.model.ScoreCursor

/**
 * Demo loop region: measures 2..3 (0-indexed: 1..2). Tap-to-pick-A/B
 * spatial UI is a Phase 5.1 follow-up; this overlay just exposes a
 * fixed range so the engine's setLoop / clearLoop paths can be exercised
 * end-to-end from the demo app.
 */
private val DEMO_LOOP_START: ScoreCursor =
    ScoreCursor.Beat(measureIndex = 1, tickInMeasure = 0)
private val DEMO_LOOP_END: ScoreCursor =
    ScoreCursor.Beat(measureIndex = 3, tickInMeasure = 0)

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
            text = if (lr != null) "Loop: measures 2–3 (${lr!!.startTick}..${lr!!.endTick})"
                   else "Loop: off (toggle to loop measures 2–3)",
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = lr != null,
            onCheckedChange = { on ->
                if (on) {
                    viewModel.engine.setLoop(from = DEMO_LOOP_START, to = DEMO_LOOP_END)
                } else {
                    viewModel.engine.clearLoop()
                }
            },
        )
    }
}
