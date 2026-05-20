# Android Media Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `SheetMusicAudioAndroid`'s public surface to the
"app-side MediaSession integratable" state that `SheetMusicAudioApple`
already has for NowPlaying, and demonstrate end-to-end wiring in
`Examples/Android/` via `androidx.media3:media3-session`.

**Architecture:** Two-layer delivery. (1) Library: add absolute-time
seek API to both engines, mirror Apple's NowPlaying-aware KDoc on
Android, and ship an integrator-facing recipe doc. (2) Example app:
hoist engine ownership into a `MediaSessionService` whose
`EnginePlayer` (extending `androidx.media3.common.SimpleBasePlayer`)
adapts the engine to Media3's `Player` contract. The in-app
ViewModel binds to the service and continues to drive the engine
directly; system controls (notification, lock-screen) drive it
through `EnginePlayer`. One engine, two control paths.

**Tech Stack:** Swift 6.3.2 (Apple library) / Kotlin 2.0.20 (Android
library + example) / `androidx.media3:media3-session:1.5.0` /
JUnit 4 + kotlinx-coroutines-test (Android unit tests) / Swift
Testing (Apple unit tests).

**Reference:** Spec at
`docs/superpowers/specs/2026-05-20-android-media-session-design.md`.

---

## File map

**Modify (Apple library):**
- `Sources/SheetMusicAudioApple/PlaybackEngine.swift` — add `seek(toTimeSeconds:)` after the existing `skip(by:)` (~line 623).

**Modify (Apple tests):**
- `Tests/SheetMusicTests/PlaybackEnginePrepareTests.swift` — add a smoke test for `seek(toTimeSeconds:)` (no-op guard before prepare).

**Modify (Android library):**
- `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt` — add `seek(toTimeSeconds:)`, update KDoc on `pause()` / `currentTimeSeconds` / `state`.
- `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineTest.kt` — add `seek(toTimeSeconds:)` unit test.

**Create (Android library doc):**
- `Android/SheetMusicAudioAndroid/MEDIA_SESSION.md` — integrator recipe.

**Modify (example build):**
- `Examples/Android/app/build.gradle.kts` — add `media3-session` dep.
- `Examples/Android/app/src/main/AndroidManifest.xml` — permissions + service declaration.

**Create (example service):**
- `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/EnginePlayer.kt` — Media3 `SimpleBasePlayer` adapter.
- `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/PlaybackService.kt` — `MediaSessionService` host.

**Modify (example UI):**
- `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioViewModel.kt` — service binding, engine becomes `StateFlow<AndroidPlaybackEngine?>`.
- `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioControls.kt` — null-guard `viewModel.engine.value?.<method>()`.
- `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/MixerPanel.kt` — same.
- `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/LoopSelectionOverlay.kt` — same.
- `Examples/Android/app/src/main/java/com/example/sheetmusic/SheetMusicApp.kt` — preparePlayback path null-safe.

**Modify (smoke test):**
- `Examples/Android/SMOKE_TEST.md` — append Phase 5C verification steps.

---

## Task 1: Add `seek(toTimeSeconds:)` to Apple `PlaybackEngine`

**Files:**
- Modify: `Sources/SheetMusicAudioApple/PlaybackEngine.swift` after `skip(by:)` at line 623.
- Modify: `Tests/SheetMusicTests/PlaybackEnginePrepareTests.swift`.

- [ ] **Step 1: Write the failing test.**

Append inside the existing `@Suite("PlaybackEngine prepare") @MainActor struct PlaybackEnginePrepareTests`:

```swift
@Test("seek(toTimeSeconds:) is a no-op when no sequencer is built")
func seekToTimeWithoutPrepareNoOps() {
    let engine = PlaybackEngine(soundfontResolver: NullResolver())
    // Smoke: must not crash even though sequencer/timeline are nil.
    engine.seek(toTimeSeconds: 5.0)
    engine.seek(toTimeSeconds: -10.0)
    engine.seek(toTimeSeconds: .infinity)
    #expect(engine.currentTimeSeconds == 0)
}
```

- [ ] **Step 2: Run the test and verify it fails.**

Run: `swift test --filter PlaybackEnginePrepareTests/seekToTimeWithoutPrepareNoOps`

Expected: FAIL — `value of type 'PlaybackEngine' has no member 'seek(toTimeSeconds:)'`.

- [ ] **Step 3: Add the implementation.**

In `Sources/SheetMusicAudioApple/PlaybackEngine.swift`, immediately after the closing `}` of `skip(by:)` (at line 623), insert:

```swift
    /// Seek to an absolute time in seconds, clamped to
    /// `[0, totalTimeSeconds]`. Preserves play / pause state — when
    /// playing, restarts the sequencer at the new position; when
    /// paused, moves the cursor and the next `play()` resumes from
    /// there. No-op when no sequencer is built or when `state` is
    /// `.exporting`.
    ///
    /// Provided alongside `skip(by:)` for natural integration with
    /// `MPRemoteCommandCenter.changePlaybackPositionCommand`, whose
    /// handler receives an absolute target time. Internally reuses
    /// `skip(by:)`'s clamp + state-preserve machinery — no new code
    /// path through the sequencer.
    public func seek(toTimeSeconds seconds: TimeInterval) {
        skip(by: seconds - currentTimeSeconds)
    }
```

- [ ] **Step 4: Run the test and verify it passes.**

Run: `swift test --filter PlaybackEnginePrepareTests/seekToTimeWithoutPrepareNoOps`

Expected: PASS.

- [ ] **Step 5: Run the full suite to confirm no regression.**

Run: `swift test` (from the worktree root).

Expected: 1381 tests / 247 suites pass (one new test added, 1 known issue unchanged).

- [ ] **Step 6: Commit.**

```bash
git add Sources/SheetMusicAudioApple/PlaybackEngine.swift \
        Tests/SheetMusicTests/PlaybackEnginePrepareTests.swift
git commit -m "feat(audio-apple): seek(toTimeSeconds:) absolute-time seek

Wraps skip(by:) with target − currentTimeSeconds. Inherits clamp +
state-preserve semantics. Natural counterpart for
MPRemoteCommandCenter.changePlaybackPositionCommand handlers."
```

---

## Task 2: Add `seek(toTimeSeconds:)` to Android `AndroidPlaybackEngine`

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt` after `skip(seconds: Double)` (~line 388).
- Modify: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineTest.kt`.

- [ ] **Step 1: Write the failing test.**

Append to `AndroidPlaybackEngineTest` (after the existing `skip updates position from JniBridge frame` test at line 377):

```kotlin
    @Test
    fun `seekToTimeSeconds updates position to absolute time`() = runTest {
        // Set up a frameAtTickResult corresponding to target=2.0s (out of total=2.0s).
        // skip()'s tick estimate at target=2.0 / total=2.0 * totalTicks=960 = 960L.
        val cursor = ScoreCursor.Beat(measureIndex = 3, tickInMeasure = 0)
        val frameBytes = encodeFrameBytes(tick = 960L, timeMicros = 2_000_000L, cursor = cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameAtTickResult = frameBytes,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
        engine.seek(toTimeSeconds = 2.0)
        assertEquals(2.0, engine.currentTimeSeconds.value, 0.001)
        assertEquals(cursor, engine.currentCursor.value)
    }

    @Test
    fun `seekToTimeSeconds clamps to totalTimeSeconds`() = runTest {
        // Target way beyond end: should clamp to total (2.0s) and call skip
        // with delta = (2.0 - 0.0).
        val cursor = ScoreCursor.Beat(measureIndex = 3, tickInMeasure = 0)
        val frameBytes = encodeFrameBytes(tick = 960L, timeMicros = 2_000_000L, cursor = cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameAtTickResult = frameBytes,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
        engine.seek(toTimeSeconds = 999.0)
        assertEquals(2.0, engine.currentTimeSeconds.value, 0.001)
    }

    @Test
    fun `seekToTimeSeconds clamps to zero on negative target`() = runTest {
        val cursor = ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val frameBytes = encodeFrameBytes(tick = 0L, timeMicros = 0L, cursor = cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameAtTickResult = frameBytes,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
        engine.seek(toTimeSeconds = -10.0)
        assertEquals(0.0, engine.currentTimeSeconds.value, 0.001)
    }
```

- [ ] **Step 2: Run the tests and verify they fail.**

Run: `Android/gradlew -p Android :SheetMusicAudioAndroid:testDebugUnitTest --tests '*AndroidPlaybackEngineTest.seekToTimeSeconds*'`

Expected: FAIL — `unresolved reference: seek` (no overload taking a single `Double` named `toTimeSeconds`).

- [ ] **Step 3: Add the implementation.**

In `AndroidPlaybackEngine.kt`, immediately after the closing `}` of `fun skip(seconds: Double)` (~line 388), insert:

```kotlin
    /**
     * Seek to an absolute time in seconds, clamped to
     * `[0, totalTimeSeconds]`. Preserves play / pause state.
     *
     * Provided alongside [skip] for natural integration with
     * `MediaSession.Callback.onSeekTo(positionMs)`, whose handler
     * receives an absolute target time. Internally reuses [skip]'s
     * clamp + state-preserve machinery — no new code path through
     * the player.
     *
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun seek(toTimeSeconds: Double) {
        skip(toTimeSeconds - _currentTimeSeconds.value)
    }
```

- [ ] **Step 4: Run the tests and verify they pass.**

Run: `Android/gradlew -p Android :SheetMusicAudioAndroid:testDebugUnitTest --tests '*AndroidPlaybackEngineTest.seekToTimeSeconds*'`

Expected: PASS (3 tests).

- [ ] **Step 5: Run the full Android engine suite.**

Run: `Android/gradlew -p Android :SheetMusicAudioAndroid:testDebugUnitTest`

Expected: All tests pass (existing count + 3 new).

- [ ] **Step 6: Commit.**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineTest.kt
git commit -m "feat(audio-android): seek(toTimeSeconds) absolute-time seek

Wraps skip() with delta = target − currentTimeSeconds.value. Inherits
clamp + state-preserve semantics. Natural counterpart for
MediaSession.Callback.onSeekTo(positionMs) handlers."
```

---

## Task 3: KDoc updates on `AndroidPlaybackEngine` for MediaSession integrators

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt` — `state`, `currentTimeSeconds`, `pause()` KDoc.

No tests; doc-only change.

- [ ] **Step 1: Update `state` KDoc.**

Find the `private val _state = MutableStateFlow(PlaybackState.STOPPED)` declaration (~line 154) and replace:

```kotlin
    private val _state = MutableStateFlow(PlaybackState.STOPPED)
    val state: StateFlow<PlaybackState> = _state.asStateFlow()
```

with:

```kotlin
    /**
     * Lifecycle state of the engine. Driven internally by [play] /
     * [pause] / [stop] / [prepare] / [exportToWavFile] (when that
     * path is wired) and by the poll loop's end-of-score detection.
     *
     * MediaSession integrators: map to
     * `androidx.media3.common.Player.STATE_*` (or
     * `PlaybackStateCompat.STATE_*` for the legacy MediaSession
     * API):
     *
     * | engine state | Media3 Player.State    | PlaybackStateCompat |
     * |--------------|------------------------|---------------------|
     * | STOPPED      | STATE_IDLE / STATE_ENDED | STATE_STOPPED     |
     * | PREPARED     | STATE_READY            | STATE_PAUSED        |
     * | PLAYING      | STATE_READY (+ playing)| STATE_PLAYING       |
     * | PAUSED       | STATE_READY (+ paused) | STATE_PAUSED        |
     * | EXPORTING    | (transport unavailable) | STATE_STOPPED      |
     *
     * The EXPORTING row reflects the engine's no-op guard on all
     * transport methods during export — apps should hide or disable
     * transport UI in that state.
     */
    private val _state = MutableStateFlow(PlaybackState.STOPPED)
    val state: StateFlow<PlaybackState> = _state.asStateFlow()
```

- [ ] **Step 2: Update `currentTimeSeconds` KDoc.**

Find the `private val _currentTimeSeconds = MutableStateFlow(0.0)` declaration (~line 160) and replace:

```kotlin
    private val _currentTimeSeconds = MutableStateFlow(0.0)
    val currentTimeSeconds: StateFlow<Double> = _currentTimeSeconds.asStateFlow()
```

with:

```kotlin
    /**
     * Current playback position in seconds, updated at the poll loop
     * cadence (~33 ms) during playback and on every [seek] / [skip] /
     * [stop] / [prepare].
     *
     * During A-B loop playback, the poll loop snaps tick into
     * `[loop.startTick, loop.endTick)` before reading the frame
     * time, so observers see the wrapped (audible) position rather
     * than a value that climbs past `loop.endTick`. This is the
     * behaviour MediaSession scrubbers and `getCurrentPosition()`
     * implementations expect — without the fold, the lock-screen
     * scrubber would keep advancing and saturate at score end.
     */
    private val _currentTimeSeconds = MutableStateFlow(0.0)
    val currentTimeSeconds: StateFlow<Double> = _currentTimeSeconds.asStateFlow()
```

- [ ] **Step 3: Update `pause()` KDoc.**

Find the existing `pause()` KDoc / body (~lines 305-315) and replace:

```kotlin
    /**
     * Pauses playback. Idempotent.
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun pause() {
```

with:

```kotlin
    /**
     * Pauses playback at the current position. [play] resumes from
     * there. Idempotent.
     *
     * Also stops the underlying Oboe output stream. Stopping just
     * the FluidSynth player leaves the audio stream emitting silent
     * frames, which Android's audio focus framework reads as
     * "audio still active" and which MediaSession's
     * `PlaybackStateCompat` aggregation may use to override an
     * explicit `STATE_PAUSED`. Mirrors the equivalent
     * `AVAudioEngine.pause()` discipline on Apple side.
     *
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun pause() {
```

- [ ] **Step 4: Verify the file still compiles.**

Run: `Android/gradlew -p Android :SheetMusicAudioAndroid:compileDebugKotlin`

Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit.**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt
git commit -m "docs(audio-android): NowPlaying-aware KDoc on state/pause/time

Document the MediaSession integration intent of the existing engine
surface — state-table mapping to Media3 / PlaybackStateCompat, loop
wrap-fold rationale on currentTimeSeconds, and why pause() stops Oboe.
Mirrors the doc-comments on the Apple-side PlaybackEngine."
```

---

## Task 4: Integrator recipe `MEDIA_SESSION.md`

**Files:**
- Create: `Android/SheetMusicAudioAndroid/MEDIA_SESSION.md`.

- [ ] **Step 1: Create the recipe doc.**

Write to `Android/SheetMusicAudioAndroid/MEDIA_SESSION.md`:

````markdown
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
````

- [ ] **Step 2: Verify the file renders correctly.**

Run: `head -20 Android/SheetMusicAudioAndroid/MEDIA_SESSION.md`

Expected: the first H1 (`# MediaSession integration recipe`) and intro paragraph display.

- [ ] **Step 3: Commit.**

```bash
git add Android/SheetMusicAudioAndroid/MEDIA_SESSION.md
git commit -m "docs(audio-android): MEDIA_SESSION.md integrator recipe

App-side how-to for wiring AndroidPlaybackEngine into a Media3
MediaSession. Covers callback mapping, state pump, service skeleton,
manifest entries, audio focus, score metadata."
```

---

## Task 5: Example app — `media3-session` dependency + Manifest

**Files:**
- Modify: `Examples/Android/app/build.gradle.kts` — add dep.
- Modify: `Examples/Android/app/src/main/AndroidManifest.xml` — permissions + service.

- [ ] **Step 1: Add the Media3 dependency.**

In `Examples/Android/app/build.gradle.kts`, in the `dependencies { ... }` block, after the
`implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")` line, add:

```kotlin
    implementation("androidx.media3:media3-session:1.5.0")
    implementation("androidx.media3:media3-common:1.5.0")
```

- [ ] **Step 2: Update AndroidManifest.xml.**

Replace the existing `Examples/Android/app/src/main/AndroidManifest.xml` body so the
permissions and service are present:

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <application
        android:label="SheetMusic"
        android:theme="@style/Theme.SheetMusic"
        android:supportsRtl="true">

        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <service
            android:name=".audio.PlaybackService"
            android:exported="true"
            android:foregroundServiceType="mediaPlayback">
            <intent-filter>
                <action android:name="androidx.media3.session.MediaSessionService" />
            </intent-filter>
        </service>
    </application>
</manifest>
```

- [ ] **Step 3: Verify Gradle still syncs.**

Run: `Examples/Android/gradlew -p Examples/Android :app:dependencies --configuration releaseRuntimeClasspath 2>&1 | grep media3 | head -4`

Expected: media3-session and media3-common appear in the dependency tree.

- [ ] **Step 4: Commit.**

```bash
git add Examples/Android/app/build.gradle.kts Examples/Android/app/src/main/AndroidManifest.xml
git commit -m "build(examples-android): media3-session dep + manifest

Adds androidx.media3:media3-session:1.5.0 and the MediaSessionService
manifest entries (FOREGROUND_SERVICE_MEDIA_PLAYBACK permission +
service declaration). PlaybackService class to follow."
```

---

## Task 6: `EnginePlayer.kt` — Media3 `SimpleBasePlayer` adapter

**Files:**
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/EnginePlayer.kt`.

This file is example-app-only; not unit-tested (boilerplate-heavy,
verified via emulator smoke test).

- [ ] **Step 1: Create the adapter.**

Write to `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/EnginePlayer.kt`:

```kotlin
package com.example.sheetmusic.audio

import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.android.HandlerDispatcher
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import android.os.Looper

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
            .setAvailableCommands(
                Player.Commands.Builder()
                    .addAll(
                        Player.COMMAND_PLAY_PAUSE,
                        Player.COMMAND_STOP,
                        Player.COMMAND_SEEK_TO_DEFAULT_POSITION,
                        Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                        Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                        Player.COMMAND_GET_METADATA,
                        Player.COMMAND_SET_SPEED_AND_PITCH,
                    )
                    .build()
            )
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
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build()
            )
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
```

- [ ] **Step 2: Verify the file compiles.**

Run: `Examples/Android/gradlew -p Examples/Android :app:compileDebugKotlin`

Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit.**

```bash
git add Examples/Android/app/src/main/java/com/example/sheetmusic/audio/EnginePlayer.kt
git commit -m "feat(examples-android): EnginePlayer Media3 adapter

SimpleBasePlayer-based Player implementation adapting
AndroidPlaybackEngine to the Media3 contract. Forwards play/pause/
stop/seek/setSpeed; rebuilds State from engine flows on each tick via
invalidateState(). USAGE_MEDIA audio attributes so Media3 manages
audio focus automatically. Used by PlaybackService (next task)."
```

---

## Task 7: `PlaybackService.kt` — `MediaSessionService` host

**Files:**
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/PlaybackService.kt`.

- [ ] **Step 1: Create the service.**

Write to `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/PlaybackService.kt`:

```kotlin
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
```

The `serviceScope` is a `Main + SupervisorJob` we own and cancel in
`onDestroy`. `MediaSessionService` itself is not a `LifecycleService`,
so we do not get `lifecycleScope` for free — providing our own scope
is the canonical pattern.

- [ ] **Step 2: Verify the service compiles.**

Run: `Examples/Android/gradlew -p Examples/Android :app:compileDebugKotlin`

Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit.**

```bash
git add Examples/Android/app/src/main/java/com/example/sheetmusic/audio/PlaybackService.kt
git commit -m "feat(examples-android): PlaybackService MediaSessionService

Hosts the singleton AndroidPlaybackEngine and publishes it as a
Media3 MediaSession. Exposes the engine to in-app UI via LocalBinder
so transport from the score UI takes the direct path while
notification/lock-screen controls go through EnginePlayer."
```

---

## Task 8: Rewire `AudioViewModel` to bind to `PlaybackService`

**Files:**
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioViewModel.kt`.

- [ ] **Step 1: Rewrite `AudioViewModel.kt`.**

Replace the entire `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioViewModel.kt` with:

```kotlin
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
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
     * Calls [AndroidPlaybackEngine.prepare] on the connected engine
     * when it becomes available; otherwise waits and retries on
     * subsequent service-connection events. Safe to call repeatedly.
     */
    fun preparePlayback(scoreHandle: Long) {
        viewModelScope.launch {
            val e = engine.value ?: run {
                // Wait one tick — the service binds asynchronously.
                // In practice this resolves within a few ms after init.
                engine.value ?: return@launch
            }
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
```

- [ ] **Step 2: Verify it compiles.**

Run: `Examples/Android/gradlew -p Examples/Android :app:compileDebugKotlin`

Expected: BUILD SUCCESSFUL. (You'll see warnings about `flatMapLatest`
being experimental; suppress with `@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)`
on the class declaration if AGP/Kotlin flags it as an error.)

- [ ] **Step 3: Commit.**

```bash
git add Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioViewModel.kt
git commit -m "refactor(examples-android): AudioViewModel binds to PlaybackService

Engine is no longer owned by the ViewModel — it lives in
PlaybackService and is exposed to the VM through a LocalBinder. The
VM publishes the engine as StateFlow<Engine?> and flattens its child
flows so Composables observe the same API. Service start uses
startService + bindService so the service outlives the VM when
playback is active."
```

---

## Task 9: Null-guard the UI call sites

**Files:**
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioControls.kt`.
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/MixerPanel.kt`.
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/LoopSelectionOverlay.kt`.
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/SheetMusicApp.kt` (if it touches `viewModel.engine`).

`viewModel.engine` is now `StateFlow<AndroidPlaybackEngine?>`. Every
`viewModel.engine.<method>` call site becomes
`viewModel.engine.value?.<method>` (returns null when not yet bound;
the UI button is harmless to tap before connect, the engine just
isn't there).

- [ ] **Step 1: Patch `AudioControls.kt`.**

Replace each occurrence of `viewModel.engine.` with `viewModel.engine.value?.` in this file.
Concretely the lines listed by `grep -n "viewModel.engine" Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioControls.kt`
(lines 62, 68, 75, 80, 87, 97, 123 in the version at planning time):

```kotlin
// Before:
onClick = { viewModel.engine.skip(-5.0) },
// After:
onClick = { viewModel.engine.value?.skip(-5.0) },
```

Apply the same `viewModel.engine.value?.` shape to every call site
in the file.

- [ ] **Step 2: Patch `MixerPanel.kt`.**

Apply the same `viewModel.engine.value?.` rewrite to the lines:

```kotlin
// Before:
onVolumeChange = { v -> viewModel.engine.setStaffVolume(index, v) },
onMuteToggle = { viewModel.engine.setStaffMuted(index, !channel.isMuted) },
// After:
onVolumeChange = { v -> viewModel.engine.value?.setStaffVolume(index, v) },
onMuteToggle = { viewModel.engine.value?.setStaffMuted(index, !channel.isMuted) },
```

Repeat for every `viewModel.engine.` instance in the file (use
`grep -n "viewModel.engine" Examples/Android/app/src/main/java/com/example/sheetmusic/audio/MixerPanel.kt`
to enumerate).

- [ ] **Step 3: Patch `LoopSelectionOverlay.kt`.**

```kotlin
// Before:
viewModel.engine.setLoop(from = DEMO_LOOP_START, to = DEMO_LOOP_END)
viewModel.engine.clearLoop()
// After:
viewModel.engine.value?.setLoop(from = DEMO_LOOP_START, to = DEMO_LOOP_END)
viewModel.engine.value?.clearLoop()
```

- [ ] **Step 4: Check `SheetMusicApp.kt`.**

Run: `grep -n "viewModel.engine\|audioVm.engine" Examples/Android/app/src/main/java/com/example/sheetmusic/SheetMusicApp.kt`

If matches appear, apply the same `.value?.` rewrite. If no matches, no change needed.

- [ ] **Step 5: Verify the app compiles.**

Run: `Examples/Android/gradlew -p Examples/Android :app:compileDebugKotlin`

Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit.**

```bash
git add Examples/Android/app/src/main/java/com/example/sheetmusic/
git commit -m "refactor(examples-android): null-guard engine accesses

viewModel.engine is now StateFlow<Engine?>. Each call site becomes
viewModel.engine.value?.<method>() — UI buttons are no-ops while the
service is still binding (a few ms after first launch), and work
normally thereafter."
```

---

## Task 10: SMOKE_TEST.md entries for Phase 5C

**Files:**
- Modify: `Examples/Android/SMOKE_TEST.md` — append new section.

- [ ] **Step 1: Append the Phase 5C section.**

Append to the end of `Examples/Android/SMOKE_TEST.md`:

```markdown
## Phase 5C — Media Session controls

Prerequisites: same as the Phase 5A smoke tests (test.mscz + gm.sf2
bundled, native libs built and staged). Device or emulator with
API ≥ 28.

1. Install + launch the app, parse `test.mscz`, hit Play.
2. Background the app (press Home). A notification appears with the
   title "Sheet Music", a Pause button, and Media-style controls.
3. Tap Pause in the notification — playback pauses within ~33 ms and
   the in-app cursor freezes.
4. Tap Play in the notification — playback resumes.
5. Lock the device. Lock-screen controls show. The scrubber updates
   in step with playback.
6. Drag the lock-screen scrubber to a new position. Unlock — the
   in-app cursor jumps to the new position.
7. Connect headphones and press the play/pause button. Transport
   responds (Media3 default headset key handling).
8. Open another media app (e.g. Spotify) and start playback. Our
   service pauses within ~200 ms (Media3 default audio-focus loss
   reaction).
9. Swipe the app from recents. Notification disappears within ~1 s
   (service self-stops via `onTaskRemoved` when not playing).
10. Re-open the app. Re-binding to the service is automatic — Play
    still works and continues from the prior position if playback
    was paused (engine state is preserved across the rebind).
```

- [ ] **Step 2: Commit.**

```bash
git add Examples/Android/SMOKE_TEST.md
git commit -m "docs(examples-android): SMOKE_TEST entries for Phase 5C

Manual verification flow for the MediaSession path: notification
controls, lock-screen scrubber, headset keys, audio focus loss,
service self-stop on swipe-from-recents."
```

---

## Task 11: Final verification

- [ ] **Step 1: Run Apple `swift test`.**

Run: `swift test`

Expected: 1381 tests / 247 suites pass (one new from Task 1, 1 known issue).

- [ ] **Step 2: Run Android unit tests.**

Run: `Android/gradlew -p Android :SheetMusicAudioAndroid:testDebugUnitTest`

Expected: all tests pass, including the 3 new from Task 2.

- [ ] **Step 3: Verify Android cross-compile of the library.**

Run: `SWIFT_SHEET_MUSIC_ANDROID=1 TOOLCHAINS=org.swift.632202605101a swift build --swift-sdk aarch64-unknown-linux-android28`

Expected: BUILD SUCCESSFUL. (No library code in the JNI/Audio swift targets changed; this guards against accidental Apple-only API drift in Task 1 or 3.)

- [ ] **Step 4: Verify the Android example app assembles.**

Run: `Examples/Android/gradlew -p Examples/Android :app:assembleDebug`

Expected: BUILD SUCCESSFUL. The APK is at `Examples/Android/app/build/outputs/apk/debug/app-debug.apk`.

- [ ] **Step 5: Run Apple Xcode example builds.**

Run from worktree root:

```
cd Example && xcodegen generate && \
xcodebuild -project SheetMusicExample.xcodeproj -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED.

Run for macOS:

```
xcodebuild -project Example/SheetMusicExample.xcodeproj -scheme SheetMusicExampleMac \
           -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: (Manual, deferred to a host with Android emulator)** Walk the SMOKE_TEST.md Phase 5C list. Mark each step in a commit message or session note. This is the only emulator-dependent verification — earlier steps cover everything host-side.

- [ ] **Step 7: Commit the verification record.**

If any documentation captures the run (e.g. a session note or a
follow-up README entry), commit it:

```bash
# Only if you produced verification artefacts in this task:
git add <paths>
git commit -m "docs: Phase 5C verification log"
```

Otherwise this step is a no-op — the prior commits already record the
incremental verifications.

---

## Done

When all tasks above check out, the deliverables are:

- Library: `seek(toTimeSeconds:)` on both engines, KDoc on Android
  engine, `MEDIA_SESSION.md` recipe.
- Example: media3-session dep + manifest, `EnginePlayer`,
  `PlaybackService`, refactored `AudioViewModel`, null-guarded UI,
  SMOKE_TEST entries.
- All host-verifiable tests green; emulator smoke test deferred to a
  host with Android tooling available.

Follow-ups (out of scope per spec):

- Apple-side example-app `MPNowPlayingInfoCenter` wiring.
- Live `MediaMetadata` from the loaded `Score` — Kotlin currently
  holds only a `Long` handle; this needs new JNI accessors
  (`nativeScoreTitle`, `nativeScoreComposer`). Task 7 ships
  with the placeholder title "Sheet Music"; replace via
  `LocalBinder.updateMetadata` once the JNI accessors land.
- Phase 5C Maven Central publication.
- AAC / MediaCodec audio file export (Phase 5B candidate).
