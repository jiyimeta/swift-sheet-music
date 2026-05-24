package com.example.sheetmusic

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.sheetmusic.draw.DrawProgramReader
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.FileNotFoundException

private const val ASSET_NAME = "test.mscz"
private const val PAGE_WIDTH_MM = 210.0
private const val PAGE_HEIGHT_MM = 297.0

class ScoreViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow<ScoreState>(ScoreState.Loading)
    val state: StateFlow<ScoreState> = _state.asStateFlow()

    /** Emits the raw score handle once parsing succeeds, or null beforehand. */
    private val _scoreHandle = MutableStateFlow<Long?>(null)
    val scoreHandle: StateFlow<Long?> = _scoreHandle.asStateFlow()

    private var handle: ScoreHandle? = null

    init { load() }

    fun goToPage(index: Int) {
        val r = _state.value as? ScoreState.Ready ?: return
        if (index in 0 until r.pageCount) {
            _state.value = r.copy(currentPage = index)
        }
    }

    private fun load() {
        viewModelScope.launch {
            val app = getApplication<Application>()

            withContext(Dispatchers.Default) {
                val table = BravuraMetricsBuilder.buildTable(app.assets)
                SheetMusicJNI.nativeInstallSMuFLMetrics(table)
            }

            val bytes = try {
                withContext(Dispatchers.IO) {
                    app.assets.open(ASSET_NAME).use { it.readBytes() }
                }
            } catch (_: FileNotFoundException) {
                _state.value = ScoreState.MissingFixture
                return@launch
            }

            val h = withContext(Dispatchers.Default) {
                ScoreHandle.load(bytes)
            } ?: run {
                _state.value = ScoreState.ParseError("failed to parse $ASSET_NAME")
                return@launch
            }
            handle = h
            _scoreHandle.value = h.raw

            val programBytes = withContext(Dispatchers.Default) {
                SheetMusicJNI.nativeComputeLayout(h.raw,
                                                    PAGE_WIDTH_MM, PAGE_HEIGHT_MM)
            }
            if (programBytes.isEmpty()) {
                _state.value = ScoreState.ParseError("layout returned empty result")
                return@launch
            }

            val program = try {
                DrawProgramReader.decode(programBytes)
            } catch (e: Exception) {
                _state.value = ScoreState.ParseError(
                    "draw-program decode error: ${e.message}"
                )
                return@launch
            }

            _state.value = ScoreState.Ready(
                program = program,
                currentPage = 0,
                pageCount = program.pages.size.coerceAtLeast(1)
            )
        }
    }

    override fun onCleared() {
        // Intentionally do NOT close `handle`. The same raw Long is
        // referenced by PlaybackService.engine, which outlives this
        // ViewModel via the bound service. Closing here would release
        // the underlying C++ score object and make subsequent
        // engine.seek / skip / setLoop calls return invalid frames.
        // The handle is reclaimed on process death; a fresh
        // ScoreViewModel on Activity recreation creates a new handle
        // for its own layout work, but the engine keeps using the
        // pre-existing one (see AudioViewModel.preparePlayback).
        super.onCleared()
    }
}
