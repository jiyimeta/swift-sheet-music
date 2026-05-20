package com.example.sheetmusic.audio

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.LoopRange
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * ViewModel that owns an [AndroidPlaybackEngine] lifecycle tied to the
 * Android ViewModel scope. Survives configuration changes; torn down
 * when the owning Activity/Fragment is permanently destroyed.
 */
class AudioViewModel(application: Application) : AndroidViewModel(application) {

    val engine: AndroidPlaybackEngine = AndroidPlaybackEngine(
        context = application,
        soundfontResolver = AssetSoundfontResolver(application),
    )

    val state: StateFlow<PlaybackState> get() = engine.state
    val currentCursor: StateFlow<ScoreCursor?> get() = engine.currentCursor
    val currentTimeSeconds: StateFlow<Double> get() = engine.currentTimeSeconds
    val totalTimeSeconds: StateFlow<Double> get() = engine.totalTimeSeconds
    val mixerChannels: StateFlow<List<MixerChannel>> get() = engine.mixerChannels
    val currentRate: StateFlow<Float> get() = engine.currentRate
    val loopRange: StateFlow<LoopRange?> get() = engine.loopRange

    /**
     * Suspends until the engine has decoded the score, built FluidSynth
     * instances, and transitioned to [PlaybackState.PREPARED].
     *
     * Safe to call multiple times (e.g. after navigation back to the screen);
     * the engine tears down any prior state before re-preparing.
     *
     * @param scoreHandle opaque `Long` from [io.github.jiyimeta.sheetmusic.ScoreHandle.raw].
     */
    fun preparePlayback(scoreHandle: Long) {
        viewModelScope.launch {
            try {
                engine.prepare(scoreHandle)
            } catch (e: Exception) {
                // Log the error; the UI observes engine.state (stays STOPPED) and
                // leaves the Play button disabled. A follow-up should surface a
                // human-readable error state to the user.
                android.util.Log.e("AudioVM", "prepare failed: ${e.message}", e)
            }
        }
    }

    override fun onCleared() {
        engine.teardown()
        super.onCleared()
    }
}
