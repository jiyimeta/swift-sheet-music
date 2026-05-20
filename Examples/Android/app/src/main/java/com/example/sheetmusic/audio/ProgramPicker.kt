package com.example.sheetmusic.audio

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.github.jiyimeta.sheetmusic.audio.model.GMInstrument

@Composable
fun ProgramPicker(
    current: Int,
    onSelect: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val listState = rememberLazyListState()
    LaunchedEffect(Unit) {
        if (current in 0..127) listState.scrollToItem(current)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Pick a sound") },
        text = {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxWidth(),
            ) {
                items(GMInstrument.entries.toList()) { instrument ->
                    TextButton(
                        onClick = { onSelect(instrument.program) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 2.dp),
                    ) {
                        val style = if (instrument.program == current)
                            MaterialTheme.typography.bodyMedium
                        else MaterialTheme.typography.bodySmall
                        Text(
                            text = "${instrument.program}: ${instrument.displayName}",
                            style = style,
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}
