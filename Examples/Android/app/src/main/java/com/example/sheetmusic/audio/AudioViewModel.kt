package com.example.sheetmusic.audio

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.LoopRange
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * ViewModel that binds to [PlaybackService] and exposes its
 * [AndroidPlaybackEngine] singleton to Composables. The engine is
 * `null` until service-connected and non-null thereafter for the
 * ViewModel's lifetime.
 *
 * UI call sites use `viewModel.engine.value?.<method>()` directly.
 * State flows (`state`, `currentCursor`, etc.) flatten through the
 * engine flow so collectors don't need to handle the null state
 * themselves.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AudioViewModel(application: Application) : AndroidViewModel(application) {

    private val _engine = MutableStateFlow<AndroidPlaybackEngine?>(null)
    val engine: StateFlow<AndroidPlaybackEngine?> = _engine.asStateFlow()

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            _engine.value = (binder as PlaybackService.LocalBinder).engine
        }

        override fun onServiceDisconnected(name: ComponentName) {
            _engine.value = null
        }
    }

    init {
        val intent = Intent(application, PlaybackService::class.java)
        // startService keeps the service alive across unbind; bindService
        // gives us the LocalBinder for direct engine access.
        application.startService(intent)
        application.bindService(intent, connection, Context.BIND_AUTO_CREATE)
    }

    val state: StateFlow<PlaybackState> = _engine
        .flatMapLatest { it?.state ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, PlaybackState.STOPPED)

    val currentCursor: StateFlow<ScoreCursor?> = _engine
        .flatMapLatest { it?.currentCursor ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val currentTimeSeconds: StateFlow<Double> = _engine
        .flatMapLatest { it?.currentTimeSeconds ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, 0.0)

    val totalTimeSeconds: StateFlow<Double> = _engine
        .flatMapLatest { it?.totalTimeSeconds ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, 0.0)

    val mixerChannels: StateFlow<List<MixerChannel>> = _engine
        .flatMapLatest { it?.mixerChannels ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    val currentRate: StateFlow<Float> = _engine
        .flatMapLatest { it?.currentRate ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, 1.0f)

    val loopRange: StateFlow<LoopRange?> = _engine
        .flatMapLatest { it?.loopRange ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /**
     * Suspends until the engine is service-bound, then calls
     * [AndroidPlaybackEngine.prepare]. Safe to call before the
     * service connects — the coroutine suspends on the engine flow
     * and resumes on the first non-null value.
     */
    fun preparePlayback(scoreHandle: Long) {
        viewModelScope.launch {
            val e = engine.filterNotNull().first()
            try {
                e.prepare(scoreHandle)
            } catch (ex: Exception) {
                android.util.Log.e("AudioVM", "prepare failed: ${ex.message}", ex)
            }
        }
    }

    override fun onCleared() {
        getApplication<Application>().unbindService(connection)
        // Do NOT stopService — the service continues running so
        // notification/lock-screen controls keep working across
        // ViewModel lifecycle. The service self-stops in
        // onTaskRemoved when not playing.
        super.onCleared()
    }
}
