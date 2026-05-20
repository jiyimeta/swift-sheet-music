# Android Media Session readiness — design

Phase 5 sub-project C. The goal is to bring `SheetMusicAudioAndroid`'s
public surface to the same "app-side integratable" state that
`SheetMusicAudioApple`'s `PlaybackEngine` already has for iOS / macOS
NowPlaying, and to demonstrate the end-to-end wiring in
`Examples/Android/` via `androidx.media3:media3-session`. Apple-side
parity is limited to one signature addition; no shared abstraction is
introduced.

## Background

`SheetMusicAudioApple.PlaybackEngine` is "ready for app-side
`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` integration" in
three concrete senses:

1. **Observable transport state.** `state`, `currentTimeSeconds`,
   `totalTimeSeconds`, and cursor are exposed and update at the
   sequencer cadence, so an app can mirror them into NowPlaying info
   each tick.
2. **Behaviour tweaks aware of system integration.** `pause()` also
   pauses `AVAudioEngine` (otherwise iOS Control Center reads "audio
   still active" and overrides `MPNowPlayingInfoCenter.playbackState`).
   `currentTimeSeconds` folds wrap-around during loop playback so the
   lock-screen scrubber doesn't climb past `loop.endTick`.
3. **Documented intent.** Doc comments on `pause()` and
   `currentTimeSeconds` explain the above so an integrator doesn't
   undo them.

`SheetMusicAudioAndroid.AndroidPlaybackEngine` is functionally
equivalent for items 1 and 2 (StateFlow surface, `oboeStream.stop()`
in `pause()`, poll-loop wrap that snaps tick before reading time) but
lacks item 3. There is also one ergonomic gap on both sides:
`MediaSession.Callback.onSeekTo(positionMs)` (and
`MPRemoteCommandCenter.changePlaybackPositionCommand`) want an
absolute-time seek; the engines today only offer relative `skip(by:)`
or cursor `seek(to:)`.

## Scope

In:

- Library-side parity: doc + one API addition on both engines.
- Example-app demo: full `media3-session` wiring in `Examples/Android/`
  so the Phase 5C deliverable can be exercised end-to-end.
- An Android-side integrator-facing recipe doc.

Out:

- Apple-side example-app `MPNowPlayingInfoCenter` wiring. The Apple
  library was already arranged for it without the example app adopting
  it; we mirror that posture on Android (library ready + example
  optionally exercises). The example wiring on Apple stays out of
  scope.
- New shared types in `SheetMusicAudioCore`. Score metadata
  (title / composer) is `Score`-derived; runtime values
  (currentTime / totalTime / state / rate) live in engines as
  reactive properties on each platform. There is no natural shared
  DTO to extract.
- Audio focus policy in the library. The library does not call
  `AudioManager.requestAudioFocus` — that is app responsibility,
  matching the Apple library's posture (no `AVAudioSession`
  configuration in the library either).
- Maven Central publication for the new `media3-session` consumer
  recipe. Phase 5C does not block on it.

## Section 1 — Library API + doc updates

### 1.1 Absolute-time seek (both engines)

Add `seek(toTimeSeconds:)` to both engines as the natural counterpart
to the existing relative `skip(by:)`. Apple's existing `skip(by:)`
already computes a clamped target time internally; the new method is
a thin wrapper that takes the target directly.

Apple `SheetMusicAudioApple.PlaybackEngine`:

```swift
/// Seek to an absolute time in seconds, clamped to
/// `[0, totalTimeSeconds]`. Preserves play / pause state — when
/// playing, restarts the sequencer at the new position; when paused,
/// moves the cursor and the next `play()` resumes from there.
///
/// Provided alongside `skip(by:)` for natural integration with
/// `MPRemoteCommandCenter.changePlaybackPositionCommand`, whose
/// handler receives an absolute target time. Internally reuses
/// `skip(by:)`'s delta machinery — no new code path through the
/// sequencer.
public func seek(toTimeSeconds seconds: TimeInterval)
```

Implementation: compute `delta = seconds - currentTimeSeconds`, call
existing `skip(by: delta)`. Identical clamp / state-preserve
semantics for free.

Android `AndroidPlaybackEngine`:

```kotlin
/**
 * Seek to an absolute time in seconds, clamped to
 * `[0, totalTimeSeconds]`. Preserves play / pause state.
 *
 * Provided alongside [skip] for natural integration with
 * `MediaSession.Callback.onSeekTo(positionMs)`, whose handler
 * receives an absolute target time. Internally reuses [skip]'s
 * delta machinery — no new code path through the player.
 *
 * No-op when [state] is [PlaybackState.EXPORTING].
 */
fun seek(toTimeSeconds: Double)
```

Implementation analogous: `skip(toTimeSeconds - _currentTimeSeconds.value)`.

### 1.2 KDoc additions on Android engine

Add doc comments mirroring Apple's NowPlaying-aware comments. No
behaviour change; the behaviour is already correct.

- `AndroidPlaybackEngine.pause()` KDoc: explain that
  `oboeStream.stop()` is intentional for MediaSession state
  consistency — without it the Android audio session stays "active"
  and a MediaSession `STATE_PAUSED` report would race with the
  framework re-deriving playback as still running.
- `AndroidPlaybackEngine.currentTimeSeconds` KDoc: explain that the
  poll loop snaps tick into `[loop.startTick, loop.endTick)` before
  reading the frame time, so observers see the wrapped (audible)
  position rather than a value that climbs past loop end.
- `AndroidPlaybackEngine.state` KDoc: cross-reference its mapping to
  `PlaybackStateCompat.STATE_*` for MediaSession integrators
  (PREPARED / STOPPED → `STATE_STOPPED`, PLAYING → `STATE_PLAYING`,
  PAUSED → `STATE_PAUSED`, EXPORTING → MediaSession unavailable;
  app should not advertise transport during export).

### 1.3 Integrator recipe

New `Android/SheetMusicAudioAndroid/MEDIA_SESSION.md` with:

- A table mapping `MediaSession.Callback` methods (or
  `androidx.media3.session.MediaSession.Callback` for Media3) to
  `AndroidPlaybackEngine` methods.
- A recommended state-pump pattern: collect `state`,
  `currentTimeSeconds`, `currentRate` flows in a lifecycle-scoped
  coroutine, build a `PlaybackStateCompat` (or Media3 equivalent),
  call `mediaSession.setPlaybackState(...)`.
- A short code snippet (40–60 lines) demonstrating the
  `MediaSessionService` skeleton — enough to follow but not a full
  app.
- Pointers to the AndroidX docs and the official Media3 sample for
  detail beyond the snippet.

The recipe is documentation, not API. Consumers writing their own
foreground service follow it as a template.

## Section 2 — Example app demo (`Examples/Android/`)

End-to-end wiring so the Phase 5C deliverable is exercisable.

### 2.1 Build configuration

- `Examples/Android/app/build.gradle.kts`: add
  `androidx.media3:media3-session:<latest-1.x>` to dependencies.
- `Examples/Android/app/src/main/AndroidManifest.xml`:
  - `<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />`
  - `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />`
  - `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />`
    (for API ≥ 33; runtime-requested only when entering foreground
    playback for the first time)
  - `<service android:name=".audio.PlaybackService"
      android:exported="true"
      android:foregroundServiceType="mediaPlayback">`
    with the `MediaSessionService` intent-filter.

### 2.2 Service implementation

New `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/PlaybackService.kt`
extending `MediaSessionService`:

- Owns the singleton `AndroidPlaybackEngine` (moved here from
  `AudioViewModel` ownership; the ViewModel now binds to the service
  rather than constructing the engine directly).
- Constructs an `androidx.media3.session.MediaSession` backed by a
  custom `Player` adapter (`EnginePlayer`) that translates the
  Media3 `Player` interface to the engine's API.
- `EnginePlayer` minimal surface: `getPlaybackState()` → derived from
  `engine.state.value`; `play()` / `pause()` / `stop()` →
  `engine.play()` / `engine.pause()` / `engine.stop()`;
  `seekTo(positionMs)` → `engine.seek(toTimeSeconds: positionMs / 1000.0)`;
  `getCurrentPosition()` → `(engine.currentTimeSeconds.value * 1000).toLong()`;
  `getDuration()` → `(engine.totalTimeSeconds.value * 1000).toLong()`;
  `getPlaybackParameters()` reads `engine.currentRate.value`;
  `setPlaybackParameters(...)` writes via `engine.setRate(...)`.
- A `Player.Listener` notification pump: a lifecycle-scoped coroutine
  collects `engine.state` / `currentTimeSeconds` / `currentRate` and
  invokes `Player.Listener.onPlaybackStateChanged` / `onEvents` so
  Media3 keeps the notification + lock-screen UI in sync.

The `EnginePlayer` adapter is the equivalent of the integrator-recipe
snippet from §1.3, but in production form for the example app. Other
consumers can study it as a worked example.

### 2.3 Notification + media style

`MediaSessionService` auto-builds a `MediaStyle` notification when
the session is set up correctly — no manual `NotificationChannel` /
`NotificationCompat.Builder` plumbing is needed beyond the channel
creation for API ≥ 26 (one-line `NotificationManagerCompat`
`createNotificationChannel` call in `onCreate`).

### 2.4 AudioViewModel rewiring

`AudioViewModel` currently constructs the engine in its constructor.
It changes to:

- Bind to `PlaybackService` via `Intent` + `ServiceConnection` at
  `init`-time; the service exposes its singleton engine via a
  `Binder.getEngine()` accessor.
- `engine` becomes a `StateFlow<AndroidPlaybackEngine?>` (null until
  service-connected, non-null thereafter for the ViewModel's lifetime).
- StateFlows (`state`, `currentCursor`, etc.) flatten through
  `engine.flatMapLatest { it?.state ?: emptyFlow() }`.
- UI call sites (`viewModel.engine.play()`, etc.) become
  `viewModel.engine.value?.play()` — null-safe one-line edit. UI
  files (`AudioControls`, `MixerPanel`, `LoopSelectionOverlay`)
  update accordingly.

Why this shape rather than a `MediaController` round-trip: it keeps
the in-app UI on the direct engine path (zero latency, full API
surface) while still letting `MediaSession` drive system-level
controls (notification, lock screen, headset) through the same
engine instance. The two paths converge on one engine; both observe
the same StateFlows. Less invasive than `MediaController.sendCommand`
routing, and matches the Apple-side posture (app code talks to the
engine directly; system integration is a thin layer beside it).

This is purely an example-app refactor; library API unchanged.

### 2.5 Score metadata

Phase 5C ships with a hardcoded placeholder `MediaMetadata` (title
"Sheet Music", empty composer). Reading title / composer from the
loaded `Score` is deferred — the Kotlin side currently holds only a
`Long` handle, so live metadata would require a new JNI accessor
(`nativeScoreTitle(handle): String?` etc). That JNI expansion is its
own small task and is queued as a Phase 5.1 follow-up so 5C ships on
its actual deliverable (system controls). The hardcoded title is
visible in the notification and lock-screen surface — adequate for
the demo and replaceable later without re-architecting.

## Section 3 — Shared code scope

No new types in `SheetMusicAudioCore`. The natural-sharing surface is
limited to:

- `seek(toTimeSeconds:)` signature parity on both engines (§1.1).
- KDoc on Android mirrors the equivalent Apple doc-comment intent —
  not literal text-sharing, since the platform-specific subsystem
  names (AVAudioEngine vs Oboe, MPNowPlayingInfoCenter vs
  MediaSession) differ.

A `NowPlayingInfo` snapshot value type was considered. It would
contain `{title, composer, totalTimeSeconds, currentTimeSeconds,
state, rate}`. Rejected because:

- Title/composer come from `Score`, which both platforms already
  share via `SheetMusicCore`.
- The runtime values are already observable on each engine; the
  snapshot would just be a stale copy.
- Both platforms' integration code (`MPNowPlayingInfoCenter.default
  .nowPlayingInfo = [...]` on Apple, `MediaSession.setMetadata` on
  Android) wants a platform-native dict / builder, not a Swift
  struct. The snapshot would be translated immediately and
  discarded.

## Testing

### Library (unit tests, host JVM)

- `AndroidPlaybackEngineTest`: new test for `seek(toTimeSeconds:)`
  exercising the clamp + state-preserve invariants. Reuses existing
  `FakeJniBridge` + `FakePlayerDriver`.
- Apple `PlaybackEngineTests`: new test for `seek(toTimeSeconds:)`
  asserting parity with `skip(by: delta)` semantics. Reuses existing
  test fixtures.

### Example app

- No new unit tests for the Service / Player adapter (boilerplate
  thin enough that integration testing is the right level).
- Manual SMOKE_TEST.md entry for the Phase 5C path:
  1. Launch app, parse `test.mscz`, hit Play.
  2. Background the app — notification appears with title /
     composer / Media style buttons.
  3. Pause / resume from the notification — engine state mirrors
     within ~33ms.
  4. Lock the device — lock-screen controls show, scrubber updates.
  5. Drag the scrubber — engine seeks to the new position; cursor
     overlay in the in-app UI follows after unlock.
  6. Open another media app and start playback — our service pauses
     within ~200ms (audio focus loss handled by Media3 default
     behavior).

## Risk and follow-ups

- **`Player` adapter surface is large.** The Media3 `Player`
  interface has 60+ methods, most of which are no-op-able with a
  reasonable default. We implement only the transport / state /
  position / metadata subset and inherit `ForwardingPlayer`
  defaults (or `SimpleBasePlayer` if simpler) for the rest. This is
  example-app-only code, so its size doesn't bloat the library.
- **Single-engine sharing across two control paths.** In-app UI
  drives the engine directly through the ViewModel; system controls
  drive it through `MediaSession` → `EnginePlayer`. Both observe the
  same StateFlows for state updates, so the MediaSession's
  `PlaybackStateCompat` view stays consistent regardless of which
  path triggered an action.
- **Foreground service quota on API ≥ 34.** Android 14+ enforces
  `FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK` permission and audio
  start restrictions. Manifest entries (§2.1) and the requirement
  that `startForeground` is called from a user-initiated context
  (the Play button) cover this. Document in `MEDIA_SESSION.md`.
- **Apple-side example NowPlaying wiring** remains a Phase 5.1
  candidate. Library is already arranged for it; only the example
  app's `SceneDelegate` / `AppDelegate` adoption is missing.
- **Android score metadata via JNI** — Phase 5.1 follow-up to add
  `nativeScoreTitle` / `nativeScoreComposer` accessors and have
  `PlaybackService` populate `MediaMetadata` from them after
  `prepare()`.

## Non-goals (re-stated for clarity)

- Library-side audio focus handling.
- Library-side `MediaSession` construction (would force Media3
  dependency on every consumer).
- Apple-side `MPNowPlayingInfoCenter` example-app wiring.
- New `SheetMusicAudioCore` types.
- Maven Central publication of the example app's recipe.
