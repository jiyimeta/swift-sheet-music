package com.example.sheetmusic.audio

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.example.sheetmusic.MainActivity
import com.example.sheetmusic.R
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

private const val NOTIFICATION_ID = 1001
private const val CHANNEL_ID = "playback"
private const val CHANNEL_NAME = "Playback"

/**
 * Hosts the singleton [AndroidPlaybackEngine] for the example app and
 * publishes it as a Media3 [MediaSession] so system controls
 * (notification, lock screen, headset, automotive) can drive
 * playback.
 *
 * The same engine instance is exposed to in-app UI through
 * [LocalBinder.engine], so the UI calls engine methods directly (zero
 * latency, full API) while system controls go through
 * [EnginePlayer] → engine. Two paths, one engine.
 */
class PlaybackService : MediaSessionService() {

    private lateinit var engine: AndroidPlaybackEngine
    private var session: MediaSession? = null
    private val serviceScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // ── Local-binding surface (in-app UI) ────────────────────────────

    inner class LocalBinder : Binder() {
        val engine: AndroidPlaybackEngine get() = this@PlaybackService.engine
    }

    private val localBinder = LocalBinder()

    override fun onBind(intent: Intent?): IBinder? {
        // MediaSessionService handles its own bind action; for the
        // local in-app binding, return our binder.
        return when (intent?.action) {
            MediaSessionService.SERVICE_INTERFACE -> super.onBind(intent)
            else -> localBinder
        }
    }

    // ── Lifecycle ───────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        engine = AndroidPlaybackEngine(
            context = applicationContext,
            soundfontResolver = AssetSoundfontResolver(applicationContext),
        )
        val mediaItem = MediaItem.Builder()
            .setMediaId("score")
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle("Sheet Music")
                    .setArtist("")
                    .build()
            )
            .build()
        val player = EnginePlayer(engine, serviceScope, mediaItem)
        val sessionActivity = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        session = MediaSession.Builder(this, player)
            .setSessionActivity(sessionActivity)
            .build()
        ensureNotificationChannel()
        // Media3 1.5.0 + SimpleBasePlayer doesn't auto-promote the
        // service to foreground when playback starts (Media3
        // MediaNotificationManager appears not to observe our event
        // sequence — startForegroundCount stays 0 even with an
        // explicit DefaultMediaNotificationProvider). Drive the
        // foreground notification manually off the engine state.
        observeEngineForForegroundNotification()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        mgr.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) },
        )
    }

    private fun observeEngineForForegroundNotification() {
        serviceScope.launch {
            engine.state.collect { state ->
                when (state) {
                    PlaybackState.PLAYING, PlaybackState.PAUSED -> postOrUpdateNotification()
                    PlaybackState.STOPPED, PlaybackState.PREPARED, PlaybackState.EXPORTING ->
                        stopForeground(STOP_FOREGROUND_REMOVE)
                }
            }
        }
    }

    private fun postOrUpdateNotification() {
        val s = session ?: return
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_play_arrow)
            .setContentTitle("Sheet Music")
            .setStyle(MediaStyle().setMediaSession(s.sessionCompatToken))
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onGetSession(
        controllerInfo: MediaSession.ControllerInfo
    ): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = session?.player
        if (player?.playWhenReady != true) {
            // Not playing → stop the service so it doesn't linger.
            stopSelf()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        session?.run {
            player.release()
            release()
        }
        session = null
        if (::engine.isInitialized) {
            engine.teardown()
        }
        serviceScope.cancel()
        super.onDestroy()
    }
}
