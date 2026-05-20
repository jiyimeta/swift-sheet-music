package com.example.sheetmusic.audio

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import io.github.jiyimeta.sheetmusic.audio.model.GMInstrument
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel

private val mutedOverlayColor = Color(0x33FF0000) // translucent red

/**
 * Collapsible mixer panel showing per-staff volume / mute / solo controls
 * plus master volume and metronome toggle.
 *
 * Observes [AudioViewModel.mixerChannels] and delegates mutations back to
 * [AndroidPlaybackEngine] so the UI stays in sync with the engine state.
 */
@Composable
fun MixerPanel(viewModel: AudioViewModel, modifier: Modifier = Modifier) {
    val channels by viewModel.mixerChannels.collectAsState()

    // Collapse/expand state; collapsed by default to keep the score visible.
    var expanded by remember { mutableStateOf(false) }

    // Metronome local state (engine doesn't expose a StateFlow for these yet;
    // a follow-up should hoist into a MixerState in AudioViewModel).
    var metronomeEnabled by remember { mutableStateOf(false) }
    var metronomeVolume by remember { mutableStateOf(0.8f) }
    var masterVolume by remember { mutableStateOf(1.0f) }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant)
    ) {
        // Header row with collapse toggle
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = "Mixer",
                style = MaterialTheme.typography.labelLarge
            )
            TextButton(onClick = { expanded = !expanded }) {
                Text(if (expanded) "Hide" else "Show")
            }
        }

        if (expanded) {
            HorizontalDivider()

            // Per-staff rows
            if (channels.isEmpty()) {
                Text(
                    text = "No staves (prepare a score first)",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(8.dp)
                )
            } else {
                // Use a fixed-height lazy list so it doesn't push the score off screen.
                val rowHeight = 56.dp
                val maxVisible = 4
                val listHeight = rowHeight * channels.size.coerceAtMost(maxVisible)

                LazyColumn(modifier = Modifier.height(listHeight)) {
                    itemsIndexed(channels) { index, channel ->
                        StaffRow(
                            channel = channel,
                            onVolumeChange = { v -> viewModel.engine.value?.setStaffVolume(index, v) },
                            onMuteToggle = { viewModel.engine.value?.setStaffMuted(index, !channel.isMuted) },
                            onSoloToggle = { viewModel.engine.value?.setStaffSoloed(index, !channel.isSoloed) },
                            onProgramChange = { p -> viewModel.engine.value?.setStaffProgram(index, p) },
                        )
                    }
                }
            }

            HorizontalDivider()

            // Master volume row
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Master",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.width(56.dp)
                )
                Slider(
                    value = masterVolume,
                    onValueChange = { v ->
                        masterVolume = v
                        viewModel.engine.value?.setMasterVolume(v)
                    },
                    valueRange = 0f..1f,
                    modifier = Modifier.weight(1f)
                )
            }

            // Metronome row
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Click",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.width(56.dp)
                )
                Checkbox(
                    checked = metronomeEnabled,
                    onCheckedChange = { on ->
                        metronomeEnabled = on
                        viewModel.engine.value?.setMetronomeEnabled(on)
                    }
                )
                Slider(
                    value = metronomeVolume,
                    onValueChange = { v ->
                        metronomeVolume = v
                        viewModel.engine.value?.setMetronomeVolume(v)
                    },
                    valueRange = 0f..1f,
                    enabled = metronomeEnabled,
                    modifier = Modifier.weight(1f)
                )
            }
        }
    }
}

@Composable
private fun StaffRow(
    channel: MixerChannel,
    onVolumeChange: (Float) -> Unit,
    onMuteToggle: () -> Unit,
    onSoloToggle: () -> Unit,
    onProgramChange: (Int) -> Unit,
) {
    var showPicker by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(56.dp)
                .padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = channel.displayName,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.width(56.dp)
            )
            Slider(
                value = channel.volume,
                onValueChange = onVolumeChange,
                valueRange = 0f..1f,
                modifier = Modifier.weight(1f)
            )
            TextButton(
                onClick = onMuteToggle,
                modifier = Modifier.width(40.dp)
            ) {
                Text(if (channel.isMuted) "M" else "m",
                     style = MaterialTheme.typography.labelSmall)
            }
            TextButton(
                onClick = onSoloToggle,
                modifier = Modifier.width(40.dp)
            ) {
                Text(if (channel.isSoloed) "S" else "s",
                     style = MaterialTheme.typography.labelSmall)
            }
            // Program label: tappable for melodic staves, static for drums.
            val program = channel.program
            if (program != null) {
                TextButton(
                    onClick = { showPicker = true },
                    modifier = Modifier.width(72.dp),
                ) {
                    Text(
                        text = GMInstrument.forProgram(program)?.displayName ?: "P$program",
                        style = MaterialTheme.typography.labelSmall,
                        maxLines = 1,
                    )
                }
            } else {
                Text(
                    text = "Drums",
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier
                        .width(72.dp)
                        .padding(horizontal = 4.dp),
                )
            }
        }

        // Red overlay when the channel is effectively muted (solo or explicit mute).
        if (channel.effectiveMute) {
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .background(mutedOverlayColor)
            )
        }
    }
    if (showPicker) {
        val program = channel.program ?: 0
        ProgramPicker(
            current = program,
            onSelect = {
                onProgramChange(it)
                showPicker = false
            },
            onDismiss = { showPicker = false },
        )
    }
}
