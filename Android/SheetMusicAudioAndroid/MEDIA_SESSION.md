# MediaSession integration recipe

`AndroidPlaybackEngine` is library-only — it does not depend on or
construct a `MediaSession`. App code is responsible for wiring an
engine instance to `androidx.media3.session.MediaSession` (or the
legacy `MediaSessionCompat`). This document is the recommended
recipe.

## Engine surface ↔ MediaSession.Callback mapping

For Media3 `androidx.media3.session.MediaSession.Callback` (or its
internal `Player.Listener` if you implement a custom `Player`):

| MediaSession command                  | Engine call                              |
|---------------------------------------|------------------------------------------|
| `Player.play()`                       | `engine.play()`                          |
| `Player.pause()`                      | `engine.pause()`                         |
| `Player.stop()`                       | `engine.stop()`                          |
| `Player.seekTo(positionMs)`           | `engine.seek(toTimeSeconds = positionMs / 1000.0)` |
| `Player.seekForward()` (+5s default)  | `engine.skip(5.0)`                       |
| `Player.seekBack()` (-5s default)     | `engine.skip(-5.0)`                      |
| `Player.setPlaybackParameters(p)`     | `engine.setRate(p.speed)`                |

## State pump

Collect engine flows from a lifecycle-scoped coroutine in your
service or `Player` adapter, then invoke
`Player.Listener.onEvents(...)` (or the
`MediaSession.setPlaybackState` family) when any of them changes.

```kotlin
serviceScope.launch {
    combine(
        engine.state,
        engine.currentTimeSeconds,
        engine.currentRate,
    ) { state, time, rate ->
        Triple(state, time, rate)
    }.collect { (state, time, rate) ->
        listener.onPlaybackStateChanged(state.toMedia3PlaybackState())
        listener.onPositionDiscontinuity(...)  // when time jumped, not when polled
        listener.onPlaybackParametersChanged(PlaybackParameters(rate))
    }
}

private fun PlaybackState.toMedia3PlaybackState(): Int = when (this) {
    PlaybackState.STOPPED, PlaybackState.PREPARED -> Player.STATE_READY
    PlaybackState.PLAYING, PlaybackState.PAUSED -> Player.STATE_READY
    PlaybackState.EXPORTING -> Player.STATE_IDLE
}
```

The example app at `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/EnginePlayer.kt`
is a production version of this pattern using `SimpleBasePlayer` —
study it as a worked example.

## MediaSessionService skeleton

```kotlin
class PlaybackService : MediaSessionService() {
    private lateinit var engine: AndroidPlaybackEngine
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        engine = AndroidPlaybackEngine(
            context = this,
            soundfontResolver = YourSoundfontResolver(this),
        )
        val player = EnginePlayer(engine, lifecycleScope)
        session = MediaSession.Builder(this, player).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        session

    override fun onDestroy() {
        session?.release()
        engine.teardown()
        super.onDestroy()
    }
}
```

## Manifest requirements

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<service
    android:name=".PlaybackService"
    android:exported="true"
    android:foregroundServiceType="mediaPlayback">
    <intent-filter>
        <action android:name="androidx.media3.session.MediaSessionService" />
    </intent-filter>
</service>
```

API ≥ 33 must request `POST_NOTIFICATIONS` at runtime before the
service goes foreground.

API ≥ 34 enforces the `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permission
and requires `startForeground` to be called from a user-initiated
context — driving it from your Play button satisfies this.

## Audio focus

Media3's `MediaSession` requests and manages audio focus
automatically for `audioAttributes` declaring `USAGE_MEDIA`. You do
not need to call `AudioManager.requestAudioFocus` yourself. Set
attributes on the `Player`:

```kotlin
class EnginePlayer(...) : SimpleBasePlayer(...) {
    override fun getState(): State = State.Builder()
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                .build()
        )
        .setIsLoadingAd(false)
        // ... other fields
        .build()
}
```

The library does not configure audio focus because doing so would
collide with the policy you'd set here.

## Score metadata

Score title / composer are not on the engine — they come from your
loaded `Score`. Build `MediaMetadata` in your service when you call
`engine.prepare(scoreHandle)`:

```kotlin
val mediaItem = MediaItem.Builder()
    .setMediaId(scoreHandle.toString())
    .setMediaMetadata(
        MediaMetadata.Builder()
            .setTitle(score.title ?: "Untitled")
            .setArtist(score.composer ?: "")
            .build()
    )
    .build()
```

## See also

- [Media3 session module docs](https://developer.android.com/media/media3/session)
- [Background playback with a MediaSessionService](https://developer.android.com/media/media3/session/background-playback)
- Working example: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/`
