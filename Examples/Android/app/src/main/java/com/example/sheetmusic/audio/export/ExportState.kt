package com.example.sheetmusic.audio.export

import android.net.Uri

/**
 * UI-facing state machine for an audio file export operation.
 *
 * Transitions: Idle → Running → (Done | Failed | Idle-on-cancel).
 * Done / Failed return to Idle when the user dismisses the result
 * dialog via [ExportViewModel.acknowledge].
 */
sealed interface ExportState {
    object Idle : ExportState
    data class Running(val progress: Float) : ExportState
    data class Done(val uri: Uri) : ExportState
    data class Failed(val message: String) : ExportState
}
