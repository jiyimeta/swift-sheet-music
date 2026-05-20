package com.example.sheetmusic.audio

import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Media3 [SimpleBasePlayer] that adapts [AndroidPlaybackEngine] to the
 * `Player` contract consumed by `MediaSession`. Transport commands
 * forward to the engine; state is rebuilt from engine flows on every
 * change and pushed via [invalidateState].
 *
 * Only the subset of `Player` capabilities relevant to a piano-roll
 * playback engine is declared; everything else falls through to
 * `SimpleBasePlayer`'s no-op defaults.
 */
class EnginePlayer(
    private val engine: AndroidPlaybackEngine,
    serviceScope: CoroutineScope,
    private val mediaItem: MediaItem,
) : SimpleBasePlayer(Looper.getMainLooper()) {

    private val audioAttributes = AudioAttributes.Builder()
        .setUsage(C.USAGE_MEDIA)
        .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
        .build()

    private val availableCommands = Player.Commands.Builder()
        .addAll(
            Player.COMMAND_PLAY_PAUSE,
            Player.COMMAND_STOP,
            Player.COMMAND_SEEK_TO_DEFAULT_POSITION,
            Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
            Player.COMMAND_GET_METADATA,
            Player.COMMAND_GET_TIMELINE,
            Player.COMMAND_SET_SPEED_AND_PITCH,
        )
        .build()

    init {
        // Push state to listeners (and via MediaSession to controllers)
        // whenever engine flows tick. We collect on the service scope so
        // the job dies with the service.
        serviceScope.launch {
            combine(
                engine.state,
                engine.currentTimeSeconds,
                engine.currentRate,
            ) { s, t, r -> Triple(s, t, r) }.collect {
                invalidateState()
            }
        }
    }

    override fun getState(): State {
        val s = engine.state.value
        val isPlaying = s == PlaybackState.PLAYING
        val media3State = when (s) {
            PlaybackState.STOPPED -> Player.STATE_IDLE
            PlaybackState.PREPARED, PlaybackState.PAUSED, PlaybackState.PLAYING -> Player.STATE_READY
            PlaybackState.EXPORTING -> Player.STATE_IDLE
        }
        return State.Builder()
            .setAvailableCommands(availableCommands)
            .setPlaybackState(media3State)
            .setPlayWhenReady(isPlaying, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaylist(
                listOf(
                    MediaItemData.Builder(mediaItem.mediaId)
                        .setMediaItem(mediaItem)
                        .setDurationUs((engine.totalTimeSeconds.value * 1_000_000).toLong())
                        .setIsSeekable(true)
                        .build()
                )
            )
            .setCurrentMediaItemIndex(0)
            .setContentPositionMs { (engine.currentTimeSeconds.value * 1000).toLong() }
            .setAudioAttributes(audioAttributes)
            .setPlaybackParameters(PlaybackParameters(engine.currentRate.value))
            .build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        if (playWhenReady) engine.play() else engine.pause()
        return Futures.immediateVoidFuture()
    }

    override fun handleStop(): ListenableFuture<*> {
        engine.stop()
        return Futures.immediateVoidFuture()
    }

    /**
     * All seek commands map to absolute-time seek for our single-item
     * playlist, so [seekCommand] is intentionally ignored.
     */
    override fun handleSeek(
        mediaItemIndex: Int,
        positionMs: Long,
        seekCommand: Int,
    ): ListenableFuture<*> {
        engine.seek(toTimeSeconds = positionMs / 1000.0)
        return Futures.immediateVoidFuture()
    }

    override fun handleSetPlaybackParameters(
        playbackParameters: PlaybackParameters
    ): ListenableFuture<*> {
        engine.setRate(playbackParameters.speed)
        return Futures.immediateVoidFuture()
    }
}
