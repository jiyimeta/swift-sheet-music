package com.example.sheetmusic.audio.export

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Owns a single in-flight audio file export and exposes its state to
 * the UI. Cancellation deletes the partial SAF document; success leaves
 * the file in place for the user to find via their picker.
 */
class ExportViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow<ExportState>(ExportState.Idle)
    val state: StateFlow<ExportState> = _state.asStateFlow()

    private var exportJob: Job? = null

    fun start(
        playbackEngine: AndroidPlaybackEngine,
        scoreHandle: Long,
        uri: Uri,
        format: AudioFileFormat,
    ) {
        cancel()
        exportJob = viewModelScope.launch(Dispatchers.IO) {
            val resolver = getApplication<Application>().contentResolver
            val pfd = resolver.openFileDescriptor(uri, "w")
            if (pfd == null) {
                _state.value = ExportState.Failed("Could not open output URI for writing")
                return@launch
            }
            _state.value = ExportState.Running(0f)
            try {
                pfd.use { fd ->
                    playbackEngine.exportAudioFile(
                        outputFd = fd,
                        scoreHandle = scoreHandle,
                        format = format,
                        progress = { p -> _state.value = ExportState.Running(p) },
                    )
                }
                _state.value = ExportState.Done(uri)
            } catch (c: CancellationException) {
                runCatching { resolver.delete(uri, null, null) }
                _state.value = ExportState.Idle
            } catch (e: Throwable) {
                runCatching { resolver.delete(uri, null, null) }
                _state.value = ExportState.Failed(e.message ?: e.javaClass.simpleName)
            }
        }
    }

    fun cancel() {
        exportJob?.cancel()
        exportJob = null
    }

    fun acknowledge() {
        _state.value = ExportState.Idle
    }
}
