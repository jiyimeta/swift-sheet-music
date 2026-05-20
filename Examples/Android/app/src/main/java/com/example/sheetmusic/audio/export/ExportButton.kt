package com.example.sheetmusic.audio.export

import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine

private fun Uri.queryDisplayName(context: android.content.Context): String? =
    context.contentResolver.query(this, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

/**
 * Self-contained Export entry point: a TextButton that opens a format
 * picker, then launches a SAF [ActivityResultContracts.CreateDocument]
 * intent for the user to pick a save location, then hands the resulting
 * URI to [ExportViewModel] for the actual offline render.
 *
 * Progress / success / failure are surfaced through Material 3 dialogs.
 * The progress dialog is intentionally non-tap-dismissable — Cancel is
 * the only exit, which deletes the partial file via SAF.
 */
@Composable
fun ExportButton(
    playbackEngine: AndroidPlaybackEngine,
    scoreHandle: Long,
    modifier: Modifier = Modifier,
) {
    val vm: ExportViewModel = viewModel()
    val context = LocalContext.current
    var showFormatPicker by remember { mutableStateOf(false) }
    var pendingFormat by remember { mutableStateOf<ExportFormatOption?>(null) }
    val state by vm.state.collectAsState()

    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument(pendingFormat?.mime ?: "audio/wav"),
    ) { uri: Uri? ->
        val format = pendingFormat
        pendingFormat = null
        if (uri != null && format != null) {
            vm.start(playbackEngine, scoreHandle, uri, format.toAudioFileFormat())
        }
    }

    TextButton(onClick = { showFormatPicker = true }, modifier = modifier) {
        Text("Export")
    }

    if (showFormatPicker) {
        AlertDialog(
            onDismissRequest = { showFormatPicker = false },
            title = { Text("Export format") },
            text = {
                Column {
                    ExportFormatOption.entries.forEach { opt ->
                        TextButton(
                            onClick = {
                                showFormatPicker = false
                                pendingFormat = opt
                                launcher.launch("score.${opt.extension}")
                            },
                        ) { Text(opt.displayName) }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showFormatPicker = false }) { Text("Cancel") }
            },
        )
    }

    when (val s = state) {
        is ExportState.Running -> {
            AlertDialog(
                onDismissRequest = {},  // not dismissable; Cancel is the only exit
                title = { Text("Exporting…") },
                text = {
                    Column {
                        LinearProgressIndicator(
                            progress = { s.progress },
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Spacer(Modifier.height(8.dp))
                        Text("${(s.progress * 100).toInt()}%")
                    }
                },
                confirmButton = {
                    TextButton(onClick = { vm.cancel() }) { Text("Cancel") }
                },
            )
        }
        is ExportState.Done -> {
            val displayName = remember(s.uri) { s.uri.queryDisplayName(context) ?: s.uri.toString() }
            AlertDialog(
                onDismissRequest = { vm.acknowledge() },
                title = { Text("Export complete") },
                text = { Text("Saved as $displayName") },
                confirmButton = {
                    TextButton(onClick = { vm.acknowledge() }) { Text("OK") }
                },
            )
        }
        is ExportState.Failed -> {
            AlertDialog(
                onDismissRequest = { vm.acknowledge() },
                title = { Text("Export failed") },
                text = { Text(s.message) },
                confirmButton = {
                    TextButton(onClick = { vm.acknowledge() }) { Text("OK") }
                },
            )
        }
        ExportState.Idle -> {}
    }
}
