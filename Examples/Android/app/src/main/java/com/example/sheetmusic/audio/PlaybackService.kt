package com.example.sheetmusic.audio

import android.content.Intent
import android.os.Binder
import android.os.IBinder
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

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
        session = MediaSession.Builder(this, player).build()
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
