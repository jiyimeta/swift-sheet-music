package com.example.sheetmusic

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.sheetmusic.draw.DrawProgramDecoder
import com.example.sheetmusic.jni.ScoreHandle
import com.example.sheetmusic.jni.SheetMusicBridge
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

            val programBytes = withContext(Dispatchers.Default) {
                SheetMusicBridge.nativeComputeLayout(h.raw,
                                                    PAGE_WIDTH_MM, PAGE_HEIGHT_MM)
            }
            if (programBytes.isEmpty()) {
                _state.value = ScoreState.ParseError("layout returned empty result")
                return@launch
            }

            val program = try {
                DrawProgramDecoder.decode(programBytes)
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
        handle?.close()
        super.onCleared()
    }
}
