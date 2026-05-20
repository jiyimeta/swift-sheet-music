package com.example.sheetmusic.audio

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.example.sheetmusic.audio.export.ExportButton
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import kotlin.math.floor

/**
 * Playback transport bar: Play/Pause/Resume, Stop, ±5 s skip, and a
 * time readout. Binds directly to an [AudioViewModel].
 *
 * Seek-to-note is handled via the [onSeekCallback] hook; callers should
 * wire it to [AudioViewModel.engine.seek] through [ScoreCanvas]'s tap
 * handler once tap → cursor mapping is implemented in a follow-up phase.
 * The hook is intentionally separate from this composable so it stays
 * decoupled from the canvas layer.
 *
 * Note: material-icons-extended is intentionally not added as a dependency.
 * Transport actions use text labels (⏮ ⏸ ⏹ ⏩) and the core PlayArrow icon.
 * Add "androidx.compose.material:material-icons-extended" to app/build.gradle
 * if you want proper icon shapes.
 */
@Composable
fun AudioControls(
    viewModel: AudioViewModel,
    scoreHandle: Long?,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsState()
    val currentSecs by viewModel.currentTimeSeconds.collectAsState()
    val totalSecs by viewModel.totalTimeSeconds.collectAsState()
    val rate by viewModel.currentRate.collectAsState()

    val isPrepared = state != PlaybackState.STOPPED && state != PlaybackState.EXPORTING

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            // Rewind 5 s
            TextButton(
                onClick = { viewModel.engine.skip(-5.0) },
                enabled = isPrepared
            ) { Text("-5s") }

            // Stop
            TextButton(
                onClick = { viewModel.engine.stop() },
                enabled = isPrepared && state != PlaybackState.PREPARED
            ) { Text("Stop") }

            // Play / Pause / Resume
            when (state) {
                PlaybackState.PLAYING -> {
                    TextButton(onClick = { viewModel.engine.pause() }) {
                        Text("Pause")
                    }
                }
                PlaybackState.PAUSED -> {
                    IconButton(onClick = { viewModel.engine.play() }) {
                        Icon(Icons.Default.PlayArrow, contentDescription = "Resume")
                    }
                }
                else -> {
                    // STOPPED, PREPARED, EXPORTING
                    IconButton(
                        onClick = { viewModel.engine.play() },
                        enabled = state == PlaybackState.PREPARED
                    ) {
                        Icon(Icons.Default.PlayArrow, contentDescription = "Play")
                    }
                }
            }

            // Forward 5 s
            TextButton(
                onClick = { viewModel.engine.skip(5.0) },
                enabled = isPrepared
            ) { Text("+5s") }

            // Export to audio file (only enabled once a score handle exists)
            if (scoreHandle != null) {
                ExportButton(
                    playbackEngine = viewModel.engine,
                    scoreHandle = scoreHandle,
                )
            }
        }

        // Time readout
        if (isPrepared) {
            Text(
                text = "${formatTime(currentSecs)} / ${formatTime(totalSecs)}",
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier
                    .align(Alignment.CenterHorizontally)
                    .padding(bottom = 4.dp)
            )
            // Rate slider
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp)
            ) {
                Text(
                    text = "Speed: %.2fx".format(rate),
                    style = MaterialTheme.typography.bodySmall,
                )
                Slider(
                    value = rate,
                    onValueChange = { viewModel.engine.setRate(it) },
                    valueRange = 0.5f..2.0f,
                    steps = 29,
                )
            }
        }
    }
}

private fun formatTime(seconds: Double): String {
    val s = seconds.coerceAtLeast(0.0)
    val minutes = floor(s / 60).toLong()
    val secs = floor(s % 60).toLong()
    return "%02d:%02d".format(minutes, secs)
}
