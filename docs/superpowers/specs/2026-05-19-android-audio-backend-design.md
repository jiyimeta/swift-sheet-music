# Android audio backend — `SheetMusicAudioAndroid` Kotlin module (Android port Phase 4 audio)

**Status:** draft (2026-05-19)
**Worktree:** TBD (`.claude/worktrees/android-audio-backend` off `main`)
**Roadmap:** Phase 4 audio — the audio half of Phase 4 that the Phase 4
(non-audio) Compose example spec
(`2026-05-19-android-compose-example-design.md`) intentionally deferred.
**Predecessors required to be merged first:**
- Phase 3 (Audio backend DI, merge commit `3041f00`) — splits
  `SheetMusicAudio` into `Core` + `Apple`. Already on `main`.
- Phase 4 non-audio (Compose example JNI bridge, branch
  `worktree-android-compose-example`) — establishes
  `SheetMusicAndroidJNI`, `HandleTable`, `DrawProgram` binary
  serialization, `Examples/Android/` Gradle layout. Spec lands first
  so its primitives can be reused.

## Goal

Ship a fully working Android audio playback layer for Compose apps
consuming `swift-sheet-music`, with API ergonomics on Android matching
the turnkey "`import SheetMusicAudio` and you are done" experience
that Apple developers already enjoy.

The implementation lives in a **new Kotlin Gradle module**
`Android/SheetMusicAudioAndroid/` published as an `.aar`, peer to
`Sources/SheetMusicAudioApple/`. It depends on FluidSynth (LGPL,
dynamically linked via a Maven-distributed `.aar` such as
`dev.atsushieno:fluidsynth-android` or equivalent — exact coordinate
vetted in the implementation plan) for SoundFont synthesis, and on
Oboe (Apache-2.0) for low-latency PCM output.

Swift-side changes are confined to **one new file**
`Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`, exposing 8–10
`@_cdecl` entry points that hand the Kotlin layer the data it needs:
SMF bytes, `PlaybackTimeline` frames, metronome beats, per-staff bank
/ program / drum flags, pitch / staff lookup for a `NoteID`.

## Non-goals

- **Swift-native Android playback engine.** No new `Sources/SheetMusicAudioAndroid/`
  Swift target, no `CFluidSynth` / `COboe` cTargets, no `.so`
  vendoring inside the SwiftPM tree. FluidSynth + Oboe come in via
  Gradle dependencies for the Kotlin module only.
- **`AudioBackend` protocol abstraction.** Phase 3 deferred this; we
  commit to *not* introducing it. Apple and Android each ship a
  concrete `PlaybackEngine` (Swift) / `AndroidPlaybackEngine` (Kotlin)
  with parallel APIs by convention. There is no Swift consumer that
  needs a polymorphic backend.
- **Full Apple `PlaybackEngine` feature parity in v0.** Loop region
  playback (`setLoop` / `clearLoop`), variable playback rate
  (`setRate`), per-staff program switching at runtime (`loadProgram`
  in the Apple mixer extension), and audio-file export (WAV / AIFF /
  M4A / MP3) are deferred to a follow-up Phase 5. The Android API
  surface in v0 simply omits these methods; library users on Android
  do not see them.
- **Maven Central publication.** v0 distributes via Gradle composite
  build (`includeBuild`) from `Examples/Android/`. JitPack / GitHub
  Packages and eventually Maven Central are explicit follow-ups.
- **MediaSession / lock-screen integration.** Apple side has it
  (`MPNowPlayingInfoCenter`); Android equivalent is `MediaSession` /
  `MediaSessionService`. Out of v0.
- **iOS / macOS code changes.** `Sources/SheetMusicAudioCore/` and
  `Sources/SheetMusicAudioApple/` stay byte-for-byte unchanged. Apple
  developers see no diff.
- **Distribution of GPL-3.0 test fixtures via the Kotlin module.**
  Existing `Tests/SheetMusicTests/Resources/` GPL files are confined
  to the Swift test target and never enter the `.aar`. The Kotlin
  test fixtures use MIT-only synthetic data.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ SheetMusicAudio  (umbrella; existing Swift target)                  │
│   SheetMusicAudio.swift:                                            │
│     @_exported import SheetMusicAudioCore                           │
│     #if canImport(AVFoundation)                                     │
│       @_exported import SheetMusicAudioApple                        │
│     #endif                                                          │
│   (Android branch deliberately stays bare — see "Why no Android     │
│    Swift sibling target" below.)                                    │
└─────────────────────────────────────────────────────────────────────┘
        ▲                            ▲
        │ Apple only                 │ all platforms
        │                            │
┌───────┴───────────────┐  ┌─────────┴────────────────────────────────┐
│ SheetMusicAudioApple  │  │ SheetMusicAudioCore                       │
│ (existing, unchanged) │  │ (existing, unchanged)                     │
└───────────────────────┘  └──────────────────────────────────────────┘

Android consumer:
┌─────────────────────────────────────────────────────────────────────┐
│ Sources/SheetMusicAndroidJNI/             (existing Phase 4 target) │
│   + AudioMidiBridge.swift  ── NEW (≤ 200 LOC)                       │
│       @_cdecl bridge: render SMF / lookup frames / staff params /   │
│       metronome beats / pitch+staff of note                         │
│   depends on: SheetMusicCore, SheetMusicMIDI, SheetMusicAudioCore,  │
│               SheetMusicMSCX, SheetMusicMusicXML, SheetMusicLayout  │
│   (already declared in Phase 4 worktree; AudioCore is added here.)  │
└─────────────────────────────────────────────────────────────────────┘
                                  ▲ JNI (jlong handle + jbyteArray blobs)
                                  │
┌─────────────────────────────────┴───────────────────────────────────┐
│ Android/SheetMusicAudioAndroid/           ── NEW Gradle module      │
│   produces a sheet-music-audio-android.aar                          │
│   namespace: io.github.kiichiio.sheetmusic.audio                    │
│                                                                     │
│   src/main/kotlin/.../audio/                                        │
│     AndroidPlaybackEngine.kt        public API, mirrors Apple       │
│     FluidSynthEngine.kt             per-staff fluid_synth_t array   │
│     OboeStream.kt                   Oboe AudioStreamCallback wrap   │
│     PlayerDriver.kt                 fluid_player wrap (load/play/   │
│                                       seek/stop)                    │
│     MetronomeMixer.kt               percussion synth + beat sched   │
│     SoundfontResolver.kt            Kotlin interface (host impls)   │
│     model/                                                          │
│       PlaybackState.kt              enum mirror                     │
│       MixerChannel.kt                                                │
│       ScoreCursor.kt                value class mirror               │
│       NoteID.kt / ScoreItemID.kt    value class mirrors             │
│       MetronomeBeat.kt                                              │
│       Frame.kt                                                      │
│     jni/                                                            │
│       SheetMusicAudioJNI.kt         external fun declarations +     │
│                                       System.loadLibrary call       │
│     serialization/                                                  │
│       FrameDecoder.kt                                                │
│       ScoreCursorCodec.kt                                            │
│       MetronomeBeatDecoder.kt                                        │
│       StaffParamsDecoder.kt                                          │
│       NoteIDCodec.kt                                                 │
│       ScoreItemIDCodec.kt                                            │
│                                                                     │
│   src/test/kotlin/.../audio/         off-device JVM unit tests      │
│                                                                     │
│   dependencies:                                                     │
│     api("dev.atsushieno:fluidsynth-android:<version>")  # LGPL      │
│     api("com.google.oboe:oboe:1.9.0")                   # Apache-2  │
│     api("org.jetbrains.kotlinx:kotlinx-coroutines-android:<v>")     │
└─────────────────────────────────────────────────────────────────────┘
                                  ▲
                                  │ Gradle project dependency
                                  │
┌─────────────────────────────────┴───────────────────────────────────┐
│ Examples/Android/   (existing from Phase 4 non-audio)               │
│   settings.gradle.kts:                                              │
│     includeBuild("../../Android") {                                 │
│       dependencySubstitution {                                      │
│         substitute(module("io.github.kiichiio:sheet-music-audio-    │
│                            android"))                                │
│           .using(project(":SheetMusicAudioAndroid"))                │
│       }                                                             │
│     }                                                               │
│   app/build.gradle.kts:                                             │
│     implementation("io.github.kiichiio:sheet-music-audio-android:   │
│                    0.0.0-SNAPSHOT")                                 │
│   app/src/main/jniLibs/<abi>/                                       │
│     libSheetMusicJNI.so + Swift runtime (existing Phase 4 stage)    │
│     libfluidsynth.so + liboboe.so (NEW; injected by                 │
│       SheetMusicAudioAndroid.aar via Gradle, no manual staging)     │
│   app/src/main/assets/                                              │
│     gm.sf2  (developer-supplied, gitignored — Phase 4 baseline)     │
└─────────────────────────────────────────────────────────────────────┘
```

### Why no Android Swift sibling target

A `Sources/SheetMusicAudioAndroid/` Swift target mirroring
`SheetMusicAudioApple` was considered and rejected. Costs versus
benefits:

| Concern | Swift target (rejected) | Kotlin Gradle module (chosen) |
|---|---|---|
| FluidSynth + Oboe distribution | Vendor prebuilt `.so` per ABI under `Sources/CFluidSynth/lib/<triple>/`, link via `.unsafeFlags(["-L", …])`; rebuild on NDK r-version bumps | Transitive Gradle dependency; Maven artifact handles ABI matrix |
| LGPL exposure | `.so` lives inside Swift source tree; library distributor signs off on LGPL §4 dynamic-link compliance | LGPL stays behind the Maven coordinate; downstream Gradle handles attribution |
| Realistic library user | An Android Swift app calling `PlaybackEngine.play()` from Swift — essentially no one. Android consumers write Compose / Kotlin | Compose / Kotlin consumers get a first-class Kotlin API without writing JNI |
| State / observability bridge | `@MainActor @Observable` in Swift, then JNI poll → Kotlin `StateFlow` for Compose. Two layers of mirroring | Single Kotlin `StateFlow` directly consumed by Compose |
| Audio thread interop | Oboe C++ callback → C wrapper → Swift callback → fluid_synth_write_float. Three FFI hops on the RT path | Oboe C++ callback → Kotlin callback (via JNI in fluidsynth-android binding) → fluid_synth_write_float. One FFI layer |
| Maintenance | Swift code + cTargets + .so vendoring + linker flags + state-sync glue; ~4–6 weeks initial + ongoing burden | Kotlin module + small Swift bridge file; ~1–2 weeks initial + lighter burden |
| API parity with Apple | `PlaybackEngine` symbol resolves on Android via umbrella import — symmetric on the surface | Asymmetric on the surface (`AndroidPlaybackEngine` Kotlin class), but symmetric in *capabilities*. Apple devs `import` Swift; Android devs `implementation(...)` Kotlin. Both reach the same feature set |

The deciding factor is the realistic library-user audience. Compose
developers write Kotlin; giving them an idiomatic Kotlin class that
matches `StateFlow` / `Coroutines` / `Uri` conventions serves them
better than emulating a Swift Observable through three FFI layers.

### Why no `AudioBackend` protocol

Phase 3's `2026-05-19-audio-backend-di-design.md` deferred this
explicitly: *"Phase 4 で Android backend を追加する際に protocol を切るか
どうかを判断する — 偽 interface を Phase 3 で作って Phase 4 で捨てる
コストを避ける。"* This spec answers: no protocol. Reasons:

1. The two implementations live in different languages
   (`SheetMusicAudioApple` is Swift, `SheetMusicAudioAndroid` is
   Kotlin). A Swift protocol cannot constrain the Kotlin
   implementation. A protocol would only constrain Swift consumers,
   of which there is exactly one (`SheetMusicAudioApple`) — and that
   one cannot benefit from polymorphism over a single conformer.

2. No identified consumer needs platform-agnostic audio code in
   Swift. `SheetMusicAudio`'s umbrella re-exports the right concrete
   `PlaybackEngine` per platform; consumer code calls the concrete
   type directly. YAGNI.

3. Future-proofing via a protocol would be premature abstraction —
   a second Apple backend (e.g. for tvOS-specific concerns) or a
   third platform (Linux ALSA?) is not on any roadmap.

## Component breakdown

### Swift bridge — `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`

Single new file. Each `@_cdecl` follows the Phase 4 worktree's naming
convention `Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeXxx`
and reads `scoreHandle: jlong` arguments through `HandleTable`.

```swift
@_cdecl("..._nativeRenderMidi")
public func audioMidi_renderMidi(env, clazz, scoreHandle) -> jbyteArray
    // MidiRenderer.render(score:) → MidiWriter.write(midi:) → jbyteArray

@_cdecl("..._nativeTimelineSummary")
public func audioMidi_timelineSummary(env, clazz, scoreHandle) -> jlongArray
    // [totalTicks, totalSecondsMicros, division]

@_cdecl("..._nativeFrameAtTick")
public func audioMidi_frameAtTick(env, clazz, scoreHandle, tick) -> jbyteArray
    // encoded Frame { tick, timeSecondsMicros, cursor } or empty if nil

@_cdecl("..._nativeFrameForCursor")
public func audioMidi_frameForCursor(env, clazz, scoreHandle,
                                      cursorBytes) -> jbyteArray
    // encoded Frame or empty if cursor does not resolve

@_cdecl("..._nativeMetronomeBeats")
public func audioMidi_metronomeBeats(env, clazz, scoreHandle) -> jbyteArray
    // length-prefixed array of MetronomeBeat records

@_cdecl("..._nativeStaffParams")
public func audioMidi_staffParams(env, clazz, scoreHandle) -> jbyteArray
    // length-prefixed array of (staffIndex, bankLSB, program, isDrums)
    // Kotlin SoundfontResolver uses these to resolve per-staff SF2 URIs

@_cdecl("..._nativePitchAndStaffOfNote")
public func audioMidi_pitchAndStaff(env, clazz, scoreHandle,
                                     noteIdBytes) -> jlong
    // (UInt32(pitch) << 32) | UInt32(staffIndex), or 0xFFFFFFFFFFFFFFFF
    // when the noteID no longer resolves (score mutated since)

@_cdecl("..._nativeEarliestOf")
public func audioMidi_earliestOf(env, clazz, scoreHandle,
                                  idsBytes) -> jbyteArray
    // encoded ScoreItemID? — earliest tick among a set of items.
    // Mirrors PlaybackEngine.earliest(of:)
```

`HandleTable` is the Phase 4 thread-safe table; lookup returning `nil`
on stale handle yields an empty `jbyteArray` / zero `jlong`, which the
Kotlin caller treats as an invalid-handle signal (logs and falls back
to a safe state, no crash). The bridge file ships under
`#if os(Android)` so Apple builds skip it entirely.

`Sources/SheetMusicAndroidJNI/`'s existing `Package.swift` dependency
list must add `"SheetMusicAudioCore"` (Phase 4 non-audio does not need
it; this spec is the first audio consumer).

#### SMF preprocessing for staff routing

`nativeRenderMidi` returns SMF bytes that have been **post-processed
in the bridge** before returning to Kotlin. The post-process performs
two passes over `MidiRenderer.render(score:)`'s output:

1. **Channel relabeling.** For each track `i` in `MidiFile.tracks`,
   every channel-bearing event has its channel field rewritten to
   `i & 0x0F`. This makes the staff index recoverable from
   `event.channel` alone in FluidSynth's playback callback — which
   does not surface track origin.
2. **MIDISynth quirks.** Reuse the existing
   `PlaybackEngine.postProcessForMIDISynth(midi:)` logic from
   `SheetMusicAudioApple` is **NOT applicable** here: FluidSynth has
   its own RPN / CC121 handling characteristics. The bridge applies a
   FluidSynth-tailored variant (initial scope: no transform beyond
   channel relabeling; the plan benchmarks pitch-bend / portamento
   accuracy and adds transforms only if regressions surface against
   the Apple reference output).

Pass 1 is implemented in the bridge as a fast `inout MidiFile` walk
before `MidiWriter.write`. The original `MidiRenderer` output is
untouched; only the SMF handed to Kotlin is modified.

A unit test (`renderMidi_channelRelabeled_matchesTrackIndex`) verifies
that for every event in every track of the returned SMF,
`event.channel == trackIndex`.

### Serialization format

Reuses Phase 4 worktree's `DrawProgram` binary discipline:
little-endian fixed-width integers, `Int64` for tick / time-micros,
2-byte format version at the start of every variable-length blob, no
generic encoder framework (hand-rolled per struct so failures are
loud at the version-byte mismatch).

**Spec correction (2026-05-19, post-implementation discovery):** The
original draft assumed `ScoreCursor` was a flat struct with fields
`(staff, measureIndex, voiceIndex, elementIndex, noteIndexInChord?)`.
The actual `Sources/SheetMusicCore/` types are richer — `ScoreCursor`
is a 2-case enum, `ScoreItemID` is a 4-case enum, `StaffAddress` is a
struct (not enum), and `ClefAnchor` carries either a `VoiceElementID`
or a bare `StaffAddress`. The codec format below reflects the actual
types; it is what implementers should write against, not the original
draft text in earlier sections.

Building blocks (no version byte — used inside other codecs):

```
StaffAddress                           8 bytes (fixed)
  i32 partIndex
  i32 staffIndexInPart

VoiceElementID                         20 bytes (fixed)
  StaffAddress (8)
  i32 measureIndex
  i32 voiceIndex
  i32 elementIndex

NoteIDPayload                          24 bytes (fixed)
  StaffAddress (8)
  i32 measureIndex
  i32 voiceIndex
  i32 elementIndex
  i32 noteIndexInChord

RestIDPayload                          20 bytes (fixed)
  StaffAddress (8)
  i32 measureIndex
  i32 voiceIndex
  i32 elementIndex

TupletIDPayload                        20 bytes (fixed)
  StaffAddress (8)
  i32 measureIndex
  i32 voiceIndex
  i32 startElementIndex

ClefAnchorPayload                      variable (1 byte + 8 or 20)
  u8 kind                       // 0=explicit, 1=staffDefault
  if kind == 0: VoiceElementID
  if kind == 1: StaffAddress

ScoreItemIDPayload                     variable (1 byte + 20 or 24)
  u8 kind                       // 0=note, 1=rest, 2=tuplet, 3=clef
  if kind == 0: NoteIDPayload
  if kind == 1: RestIDPayload
  if kind == 2: TupletIDPayload
  if kind == 3: ClefAnchorPayload

ScoreCursorPayload                     variable
  u8 kind                       // 0=item, 1=beat
  if kind == 0: ScoreItemIDPayload
  if kind == 1: i32 measureIndex
                i32 tickInMeasure
```

Top-level blobs (each starts with a `u16 version` byte):

```
NoteID                                 26 bytes
  u16 version (= 1)
  NoteIDPayload (24)

ScoreItemID                            variable
  u16 version (= 1)
  ScoreItemIDPayload

ScoreCursor                            variable
  u16 version (= 1)
  ScoreCursorPayload

Frame                                  variable
  u16 version (= 1)
  i64 tick
  i64 timeSecondsMicros        // timeSeconds × 1e6, fits piece > 200 hours
  ScoreCursorPayload           // inline, no inner version byte

MetronomeBeat (one entry inside an array, 16 bytes)
  i64 tick
  i32 kind                      // 0 downbeat, 1 upbeat, 2 subdivision
  i32 _reserved

StaffParams (one entry inside an array, 16 bytes)
  i32 staffIndex
  u8  bankLSB
  u8  program
  u8  isDrums                   // 0/1
  u8  _reserved
  i64 partAddressHash           // stable identifier across reloads

Array<T>                               length-prefixed
  u16 version (= 1)
  i32 count
  T  ... count times
```

Notes on the layout choices:
- Per-payload structs (`NoteIDPayload`, `ScoreItemIDPayload`, etc.) carry
  no version byte — they are always nested inside a versioned top-level
  blob. The version covers the whole nested tree, so a single bump
  invalidates downstream golden binaries cleanly.
- `Frame` inlines `ScoreCursorPayload` rather than a fully versioned
  `ScoreCursor` so the byte sequence is contiguous and the version
  story is single-source.
- `u8 kind` for enums (not `i32`) — saves bytes; only ≤ 4 cases per
  enum, no future expansion past 256 cases is plausible.

Each codec lives twice (Swift encoder/decoder in
`Sources/SheetMusicAndroidJNI/Audio*Codec.swift`, Kotlin decoder in
`Android/SheetMusicAudioAndroid/src/main/kotlin/.../serialization/`).
Round-trip tests on both sides assert byte-for-byte equivalence
against committed golden blobs.

### Kotlin public API — `AndroidPlaybackEngine`

```kotlin
package io.github.kiichiio.sheetmusic.audio

class AndroidPlaybackEngine(
    private val context: Context,
    private val soundfontResolver: SoundfontResolver,
) : AutoCloseable {

    // Observable state (Compose consumes via StateFlow)
    val state: StateFlow<PlaybackState>
    val currentCursor: StateFlow<ScoreCursor?>
    val currentTimeSeconds: StateFlow<Double>
    val totalTimeSeconds: StateFlow<Double>
    val mixerChannels: StateFlow<List<MixerChannel>>

    // Lifecycle
    suspend fun prepare(scoreHandle: Long)        // throws AudioBackendException
    override fun close() = teardown()
    fun teardown()

    // Playback
    fun play(from: ScoreCursor? = null)
    fun pause()
    fun stop()
    fun seek(to: ScoreCursor)
    fun skip(seconds: Double)
    fun playPreview(
        noteId: NoteID,
        duration: Duration = 300.milliseconds,
        velocity: Int = 96,
    )
    fun clearCursor()
    fun earliest(of: List<ScoreItemID>): ScoreItemID?

    // Mixer (v0 scope)
    fun setMasterVolume(volume: Float)
    fun setStaffMuted(staffIndex: Int, muted: Boolean)
    fun setStaffSoloed(staffIndex: Int, soloed: Boolean)
    fun setStaffVolume(staffIndex: Int, volume: Float)

    // Metronome (v0 scope)
    fun setMetronomeEnabled(enabled: Boolean)
    fun setMetronomeVolume(volume: Float)
}

interface SoundfontResolver {
    fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri?
    val defaultGmSoundfontUri: Uri?
}

sealed class AudioBackendException(message: String) : Exception(message) {
    class NoSoundfont(...) : AudioBackendException(...)
    class StreamUnavailable(...) : AudioBackendException(...)
    class InvalidScoreHandle(...) : AudioBackendException(...)
    class EmptyScore(...) : AudioBackendException(...)
    class TooManyStaves(staffCount: Int) : AudioBackendException(...)
    class FluidSynthInit(...) : AudioBackendException(...)
}
```

### Kotlin internals

| File | Responsibility |
|---|---|
| `FluidSynthEngine.kt` | Owns `Array<FluidSynthHandle>` (one per staff). Loads SF2 per staff. Per-staff gain / mute via `fluid_synth_set_gain`. Renders to two Float buffers per callback (`fluid_synth_write_float`) which `OboeStream` sums into the device stream |
| `PlayerDriver.kt` | Wraps `fluid_player_t`. Loads SMF via `fluid_player_add_mem` after the Swift bridge has **pre-processed it to relabel each track's events to `channel = track-index`** (see "SMF preprocessing for staff routing" below). Custom playback callback (`fluid_player_set_playback_callback`) consumes each `fluid_midi_event_t`, reads `event.channel` as the staff index, rewrites the event's channel to `0`, then dispatches via `fluid_synth_handle_midi_event` to `fluidSynthEngine.staves[staffIndex]`. Callback returns `FLUID_OK` (event was handled) so FluidSynth's default routing is suppressed. Supports `play` / `stop` / `seek_tick`. `loop` / `set_tempo` deferred |
| `OboeStream.kt` | Builds Oboe `AudioStream` (Float, 48kHz, stereo, performance-mode low-latency). `AudioStreamCallback.onAudioReady` calls into `FluidSynthEngine` and `MetronomeMixer`, applies master volume, returns. Handles `onErrorAfterClose(DISCONNECTED)` by rebuilding the stream |
| `MetronomeMixer.kt` | Standalone `fluid_synth_t` loaded with the drum-kit SF2 preset (channel 9). Owns the metronome's `beats: List<MetronomeBeat>`. A coroutine polls `fluid_player_get_current_tick` at audio rate and fires `noteon` / `noteoff` per beat. Per Apple parity, the metronome plays GM percussion notes 76 / 77 |
| `SheetMusicAudioJNI.kt` | `external fun nativeXxx(...)` declarations matching the Swift bridge. `init { System.loadLibrary("SheetMusicJNI") }`. No business logic |

### Mixer semantics

Mirrors Apple `PlaybackEngine+Mixer`:

- `isMuted=true` silences the staff regardless of solo state.
- `isSoloed=true` on any staff: every non-soloed-non-muted staff is
  effectively muted. `MixerChannel.effectiveMute` is recomputed
  whenever `_mixerChannels` changes; the Oboe callback reads this
  flag without locking (`@Volatile`).
- **Per-staff volume** is applied via `fluid_synth_set_gain` on the
  matching `fluid_synth_t`. **Master volume** is applied *once*, to
  the post-sum mix buffer in the Oboe callback. The two stages are
  independent — changing master does not write to any FluidSynth
  gain, and per-staff changes do not need master re-application.
- All ramp behavior matches Apple: instantaneous on toggle, no
  fade-in / fade-out smoothing (intentional simplicity for v0).

### Staff count limit

The SMF preprocessing scheme above (channel = track-index) imposes a
**16-staff hard limit** in v0, because MIDI's channel field is 4 bits.
Scores with > 16 staves are an error returned by `prepare`
(`AudioBackendException.TooManyStaves`). Apple's `PlaybackEngine` has
no equivalent limit (it uses out-of-band track-to-instrument routing
via `AVAudioSequencer.tracks[i].destinationAudioUnit`). Raising the
limit on Android requires either splitting the SMF into multiple
`fluid_player_t` instances (one per 16-staff bucket, sharing a tempo
track) or driving FluidSynth via manual scheduling (the "Manual
callback driver" option rejected in brainstorming). Deferred to a
follow-up phase if real-world scores demand it.

### Cursor / state propagation

Apple's `cursorTimer` fires at 30 Hz on the main run loop, reading
`AVAudioSequencer.currentPositionInBeats` and converting via
`PlaybackTimeline.frame(atTick:)`. Kotlin mirror:

```kotlin
private val pollJob: Job? = scope.launch(Dispatchers.Default) {
    while (isActive) {
        if (_state.value == PlaybackState.PLAYING) {
            val tick = playerDriver.currentTick()
            val frameBytes = SheetMusicAudioJNI
                .nativeFrameAtTick(scoreHandle, tick)
            val frame = FrameDecoder.decodeOrNull(frameBytes)
            withContext(Dispatchers.Main) {
                _currentCursor.value = frame?.cursor
                _currentTimeSeconds.value = frame?.timeSecondsMicros?.let { it / 1e6 } ?: 0.0
            }
            if (tick >= totalTicks) { stop(); continue }
        }
        delay(33)  // ~30Hz, matches Apple
    }
}
```

The poll lives entirely on Kotlin; no `@_cdecl` callback from Swift
into Kotlin is needed. Phase 4 worktree's HandleTable is thread-safe,
and `frame(atTick:)` is a pure read on `PlaybackTimeline` value
semantics, so 30 Hz JNI traffic is harmless.

## Data flow walkthroughs

### Prepare

1. `Compose ViewModel.prepareForPlayback(scoreHandle)` calls
   `engine.prepare(scoreHandle)` (suspend, dispatched on
   `Dispatchers.IO`).
2. `prepare` calls `nativeStaffParams` and decodes the per-staff
   `(bankLSB, program, isDrums)` list.
3. `prepare` calls `nativeRenderMidi` once to obtain SMF bytes.
4. `prepare` calls `nativeMetronomeBeats` for the beat schedule and
   `nativeTimelineSummary` for `totalTicks` / `totalSeconds` /
   `division`.
5. `FluidSynthEngine.setupStaves(staffParams)` creates one
   `fluid_synth_t` per staff. For each, the
   `SoundfontResolver.soundfontUriFor(bank, program, isDrums)`
   resolves to a content `Uri`; if `null`, falls back to
   `defaultGmSoundfontUri`. The `Uri` is materialized to a file
   under `context.cacheDir` (FluidSynth needs a path; content-URI
   reads happen on first access).
6. `PlayerDriver.load(smfBytes)` initializes `fluid_player_t`. The
   custom event callback dispatches each MIDI event to the
   corresponding staff's `fluid_synth`.
7. `MetronomeMixer.prepare(beats)` loads the drum-kit preset on its
   private `fluid_synth_t`.
8. `OboeStream.open(48000, stereo, callback=this::onAudioReady)`.
9. `_mixerChannels` populated with one `MixerChannel` per staff (and
   one metronome entry) at volume `1.0`, neither muted nor soloed.
10. `_state.value = PlaybackState.PREPARED`.

### Playback

`AndroidPlaybackEngine.play(from)`:

1. If `from != null`, resolve `nativeFrameForCursor(scoreHandle,
   cursorBytes)` → `frame.tick`, then `playerDriver.seekTick(tick)`.
2. `playerDriver.play()` (which internally calls `fluid_player_play`).
3. Oboe stream is running; its callback now contributes
   `fluid_synth_write_float` for each staff.
4. `_state.value = PlaybackState.PLAYING`; `pollJob` starts updating
   `currentCursor` / `currentTimeSeconds`.

`pause`:

1. `playerDriver.stop()` (FluidSynth's stop is "pause and remember"
   for `fluid_player`).
2. `oboeStream` keeps running but receives silence from each synth
   (no scheduled notes pending). The stream is *not* closed —
   reopening is expensive and would lose the audio focus.
3. `_state.value = PlaybackState.PAUSED`.

`stop`:

1. `playerDriver.stop()` + `playerDriver.seekTick(0)`.
2. All `fluid_synth.allNotesOff()` to silence ringing notes.
3. `_state.value = PlaybackState.STOPPED`, `_currentCursor.value = null`.

### Preview

`playPreview(noteId, duration, velocity)`:

1. `nativePitchAndStaffOfNote(scoreHandle, noteIdBytes)` returns
   `(pitch, staffIndex)`. Sentinel `0xFFFF…` is treated as "noteId
   no longer resolves" and the call is a no-op.
2. `fluidSynthEngine.staves[staffIndex].noteOn(channel=0, pitch, velocity)`.
3. `scope.launch { delay(duration); fluidSynthEngine.staves[staffIndex].noteOff(0, pitch) }`.
4. Preview does not touch `playerDriver`; main playback continues
   alongside preview tones if active.

### Seek

`seek(to: cursor)`:

1. `nativeFrameForCursor(scoreHandle, cursorBytes)` → `frame.tick`.
2. `fluidSynthEngine.allStaves.allNotesOff()` to kill ringing notes.
3. `playerDriver.seekTick(tick)`.
4. `_currentCursor.value = cursor`. If state is `PLAYING`, audio
   continues seamlessly; if `PAUSED`, position is updated but no
   audio plays until `play()`.

### Mixer

`setStaffMuted(staffIndex, muted)`:

1. Updates `_mixerChannels.value[staffIndex].isMuted` (immutable
   replace via `update { it.toMutableList().also { ... } }`).
2. `recomputeEffectiveMute()` walks the list applying solo
   precedence and writes `effectiveMute` per entry.
3. The Oboe callback's next iteration reads `effectiveMute` and
   skips muted staves in the per-staff sum.

`setStaffVolume(staffIndex, volume)`:

1. Updates `_mixerChannels.value[staffIndex].volume`.
2. `fluidSynthEngine.staves[staffIndex].setGain(volume)` propagates
   the new gain to FluidSynth. Master volume is *not* baked in here —
   it's applied once to the summed buffer in the Oboe callback.

`setStaffSoloed(staffIndex, soloed)`:

1. Updates `isSoloed` on the channel.
2. `recomputeEffectiveMute()` — Apple parity: if any channel has
   `isSoloed == true && isMuted == false`, every non-soloed
   non-muted channel becomes effectively muted.

### Metronome

`setMetronomeEnabled(true)`:

1. `MetronomeMixer.isEnabled = true`.
2. A coroutine launched at `prepare` time tracks `playerDriver.currentTick()`
   and, when a tick crosses any beat in `beats`, fires
   `metronome.synth.noteOn(channel=9, pitch=beat.kind == DOWNBEAT ? 76 : 77, velocity=…)`
   followed by a 100ms-later `noteOff`. Beat-velocity mapping
   follows Apple's `MetronomeController` (downbeat 96, upbeat 72,
   subdivision 56).
3. The Oboe callback sums the metronome synth into the master
   buffer alongside the staff synths.

## Errors / edge cases

### SoundFont resolution

- **No SF2 anywhere.** `prepare` throws `AudioBackendException.NoSoundfont`.
  App-side catches and renders a "no audio device" hint, leaving
  Play button disabled.
- **Per-staff SF2 fails to load** (resolver returns Uri but file is
  bad or missing). Mirrors Apple `PlaybackEngine.prepare`: `try?
  loadSoundFont` style. The staff's `fluid_synth_t` exists but plays
  silence; routing graph stays intact.
- **content:// Uri not directly path-able.** Kotlin
  `SoundfontResolver` interface returns `Uri`. The Kotlin engine
  resolves to a cached `File` via `context.contentResolver.openInputStream`
  copied to `context.cacheDir/sf2-cache/<hash>.sf2` (one-time per
  Uri, evicted on `teardown`). Re-uses cache between staves that
  share an Uri.

### Oboe / audio system

- **`AudioStream.open` fails.** Captured via Oboe's `Result`.
  `prepare` throws `AudioBackendException.StreamUnavailable`. Host
  shows an alert; no fallback path.
- **`AudioFocus` loss** (call, alarm, other media app). Engine
  registers an `AudioFocusRequest` at `prepare`; `LOSS` /
  `LOSS_TRANSIENT` triggers `pause()`. `GAIN` does *not* auto-resume
  — Apple's lock-screen flow does not auto-resume either.
- **Stream callback exception.** Oboe's RT callback must not throw.
  All exception sites inside are caught and replaced with a silence
  fill plus a `volatile` error flag that the next non-RT poll
  surfaces.
- **Device change** (Bluetooth toggle). Oboe's `onErrorAfterClose(DISCONNECTED)`
  callback closes the stream, then `OboeStream.openOrReopen` builds
  a new one. Currently playing state survives, audio drops out for
  ~100ms.

### FluidSynth internals

- **`new_fluid_synth` OOM.** Throws `AudioBackendException.FluidSynthInit`.
  Likely on scores with extreme staff counts on low-RAM devices.
- **`fluid_player_get_current_tick` bug** on certain FluidSynth 3.x
  builds. The plan's first task is to verify the chosen
  `fluidsynth-android` artifact does not exhibit it; if it does,
  fall back to deriving the current tick from elapsed wall-clock
  time × (division × tempo / 60).
- **Player thread teardown hang.** Always call `fluid_player_stop`
  → `fluid_player_join` (with a 1s timeout) before
  `delete_fluid_player`. The Kotlin engine wraps this sequence and
  surfaces a warning if the join times out, then proceeds with
  `delete_fluid_player` anyway.

### JNI / serialization

- **Invalid `scoreHandle`.** Swift bridge returns empty `jbyteArray`
  / sentinel `jlong`. Kotlin decoders treat empty input as missing
  data and `prepare` throws `AudioBackendException.InvalidScoreHandle`.
- **Binary format drift.** Every variable-length blob starts with a
  `u16 version` byte. Decoder version mismatch throws a loud
  exception (not silent fallback). Round-trip tests on both sides
  pin golden blobs; CI fails on inadvertent format change.
- **30 Hz JNI cost.** `nativeFrameAtTick` measured at <1ms per call
  on x86_64 emulator; benchmark on arm64 device during plan
  execution.
- **`nativeRenderMidi` blob size.** SMF for typical scores is
  tens-of-KB; even multi-hour scores fit in <2MB. Single allocation
  per `prepare`, no JNI thrashing.

### Lifecycle / concurrency

- **`prepare` on UI thread.** `prepare` is `suspend` and internally
  dispatches blocking work (SF2 file copy, `fluid_synth_sfload`) to
  `Dispatchers.IO`. Calling from Compose `LaunchedEffect` is the
  recommended pattern; documented in the example app.
- **Repeated `prepare` calls.** `prepare` acquires an internal
  `Mutex`; the second invocation waits for the first to complete
  (or fail). If the new `scoreHandle` differs, the engine fully
  tears down before re-preparing.
- **Activity backgrounding.** Audio continues by default (music-app
  semantics). Host can override by calling `pause()` in `onStop`.
- **`teardown` during active callback.** Oboe stream is `requestStop`-ed
  before any `delete_fluid_synth`. A `@Volatile var isTornDown`
  flag causes the callback to early-return zeros even if it fires
  after `requestStop` but before the close completes.
- **`playPreview` rapid taps.** Each preview owns its own coroutine
  scheduling its `noteOff`. Multiple in flight on the same pitch is
  acceptable — FluidSynth handles duplicate `noteOn` / `noteOff`
  on the same channel/pitch by reference-counting.

### Score / mixer

- **Empty score.** `prepare` throws `AudioBackendException.EmptyScore`.
- **All staves muted.** The Oboe callback returns silent buffers;
  the stream stays open.
- **All staves soloed.** Equivalent to no solo (no effective change).
- **Score with > 16 staves.** Hard error in v0 — `prepare` throws
  `AudioBackendException.TooManyStaves(staffCount)`. See "Staff count
  limit" above. Apple side accepts any count; the Android limit is
  documented in `Android/SheetMusicAudioAndroid/README.md`. Future
  raise: bucket SMF across multiple `fluid_player_t` instances.
- **Memory pressure on dense scores.** Per-staff `fluid_synth_t`
  loads the SF2 into its voice pool. For an 8-staff score with a
  ~50MB GM SoundFont, this is ~400MB worst case (more typically
  shared between staves with identical bank/program). The plan
  benchmarks; if pressure is observed, the follow-up task investigates
  `fluid_synth_add_sfont` sharing patterns or graduates to the
  single-fluid_synth-with-channel-per-staff architecture
  (see "Alternative architectures considered" below).

### Cross-platform `SoundfontResolver` naming

Swift `SoundfontResolver` (Foundation in `SheetMusicAudioCore`):
```swift
public protocol SoundfontResolver: Sendable {
    func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL?
    var defaultGMSoundfontURL: URL? { get }
}
```

Kotlin `SoundfontResolver`:
```kotlin
interface SoundfontResolver {
    fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri?
    val defaultGmSoundfontUri: Uri?
}
```

Same semantics, idiomatic in each language. Documented in
`Android/SheetMusicAudioAndroid/README.md` with a side-by-side
example so Apple developers porting to Android know the mapping.

### Maven dep vetting (Plan task)

The plan's first task verifies `dev.atsushieno:fluidsynth-android`
(or current equivalent) against:

1. Active maintenance (last commit, open critical issues).
2. LGPL compliance — dynamic-link `.aar` distribution, source
   reference in attribution.
3. ABI coverage: `arm64-v8a` and `x86_64` minimum.
4. FluidSynth 3.x feature coverage — `fluid_player_get_current_tick`,
   `fluid_player_seek`, `fluid_player_set_playback_callback`,
   `fluid_synth_set_gain`, `fluid_synth_sfload` with `reset_presets`.
5. License compatibility with MIT consumers (LGPL §4 dynamic-link
   is OK; static link or modification is not).

Fallback options if vetting fails:
1. Different maintained fork from JitPack.
2. Self-host: build FluidSynth from source via NDK in a CI job;
   produce a private `.aar` published from this repo.
3. Switch to TinySoundFont (LGPL → MIT, smaller, less SF2 coverage)
   as a more constrained backend.

The spec leaves this decision to the plan; the architecture above
holds regardless of which `fluidsynth-android` artifact wins.

## Testing strategy

### Swift bridge tests (`Tests/SheetMusicTests/AndroidJNI/`)

`AudioMidiBridgeTests.swift` (Apple host only,
`#if !os(Android)`):
- `renderMidiReturnsValidSMF` — parse Score fixture, call bridge,
  re-parse with `MidiParser`, assert track count and tick total
  match `PlaybackTimeline`.
- `timelineSummaryRoundTrip` — three components match `PlaybackTimeline`
  directly.
- `frameAtTickMatchesPlaybackTimeline` — sample 100 ticks, verify
  each frame matches `timeline.frame(atTick:)`.
- `frameForCursorMatchesPlaybackTimeline` — round-trip a known
  cursor.
- `staffParamsExtractsBankProgramDrums` — instruments with
  drum-kit / GM patch / bank-LSB variants.
- `pitchAndStaffOfNote_resolvesValid` and `_rejectsStaleNote`.
- `metronomeBeatsMatchPlaybackTimeline` — beat list equality.
- `earliestOfMatchesPlaybackTimeline`.
- Golden-blob round trips for each codec
  (`Frame` / `ScoreCursor` / `NoteID` / `ScoreItemID` /
  `MetronomeBeat` / `StaffParams`).

### Kotlin module tests (`Android/SheetMusicAudioAndroid/src/test/kotlin/`)

Off-device JVM tests, no FluidSynth invocation:
- `FrameDecoderTest`, `ScoreCursorCodecTest`,
  `MetronomeBeatDecoderTest`, `StaffParamsDecoderTest`,
  `NoteIDCodecTest`, `ScoreItemIDCodecTest` — decode the same golden
  blobs the Swift tests pin against.
- `MixerStateTest` — `recomputeEffectiveMute` semantics under
  combinations of mute / solo state.
- `AndroidPlaybackEngineStateMachineTest` — using fake
  `FluidSynthEngine` / `OboeStream` / `PlayerDriver`, verify state
  transitions and `StateFlow` emissions for `prepare → play → pause
  → seek → stop → teardown`.
- `MetronomeBeatScheduleTest` — fake clock, fake
  `fluidSynthEngine`, verify which beats fire when `currentTick`
  crosses configured beats.

### Golden binary round-trip

`Tests/SheetMusicTests/Resources/Golden/Audio/` (new):
- `frame-v1.bin`
- `cursor-v1.bin`
- `noteId-v1.bin`
- `scoreItemId-v1.bin`
- `metronomeBeat-v1.bin`
- `staffParams-v1.bin`

Each generated by Swift encoder during a Swift-only test, asserted
byte-for-byte against the committed file (CI fail on drift). The
same files are copied to `Android/SheetMusicAudioAndroid/src/test/resources/`
and decoded by Kotlin tests with expected values verified inline.

Format version bumps are intentional: update the version constant in
both encoders, regenerate golden, commit both. CI catches accidental
drift.

### Apple regression

No Apple-side source changes mean no Apple-side test regressions.
The plan verifies:
- `swift test` — full 1119+ green, no new test additions on Apple-only
  paths.
- `swift test --filter MidiExportTests` — 12 MuseScore-equivalence
  cases unchanged.
- `swift test --filter PlaybackEngine` and `…AudioFileExport…` —
  Apple-only paths green.
- Mac UI manual smoke (`SheetMusicExampleMac`) per memory
  `feedback_visual_verify_mac`.
- iOS Simulator build (Phase 4 worktree precedent).

### Android cross-compile

`Scripts/android-test.sh aarch64` and `… x86_64`:
- Existing Foundation-only tests green on Android device.
- New `AudioMidiBridge` Swift tests run on **Apple host only**
  (`#if !os(Android)` — the JNI bridge is `#if os(Android)`, so
  invoking it from a host test makes no sense).
- The Android device run validates that `SheetMusicAndroidJNI`
  still links with `SheetMusicAudioCore` added as a dependency.

### Gradle CI (NEW)

`.github/workflows/android-audio.yml`:
```yaml
- runs-on: ubuntu-latest
  steps:
    - checkout
    - setup-java JDK 17
    - cache Gradle
    - run: ./gradlew -p Android :SheetMusicAudioAndroid:testDebugUnitTest
    - run: ./gradlew -p Android :SheetMusicAudioAndroid:assembleRelease
```

### Manual audible smoke (Examples/Android/)

`Examples/Android/SMOKE_TEST.md` (new) — checklist to run on a
physical device and on x86_64 emulator before merge:

- [ ] Prepare a score → Play button enables
- [ ] Tap Play → audio starts; cursor follows
- [ ] Tap Pause → audio halts within ~100ms
- [ ] Tap Stop → audio halts, cursor clears
- [ ] Tap a note while playing → audio jumps to that note's onset
- [ ] Tap a note while paused → cursor moves; Play resumes from there
- [ ] Skip ±5s → cursor jumps; playback continues
- [ ] Tap a note when stopped → preview plays
- [ ] Mute staff 0 → that staff goes silent; others continue
- [ ] Solo staff 1 → only staff 1 is audible
- [ ] Solo staffs 1, 3 → both are audible, others muted
- [ ] Set staff 2 volume to 0.0 → staff 2 silent; others normal
- [ ] Set master volume to 0.0 → all silent; UI unchanged
- [ ] Toggle metronome on during playback → wood-block ticks
- [ ] Toggle metronome off → ticks stop, music continues
- [ ] Plug in BT headphones during playback → audio routes to BT
      (brief gap allowed, no crash)
- [ ] Unplug BT → audio routes back to device speaker
- [ ] Incoming phone call → playback pauses
- [ ] Background app → playback continues by default
- [ ] Configuration change (rotate) → playback continues from same
      tick, mixer state preserved
- [ ] Large score (≥ 30 staves) → prepare under 3s; memory under 250MB

## Branch / worktree layout

```
worktree:  .claude/worktrees/android-audio-backend   (new, per memory
                                                      feedback_worktree_layout)
branch:    feature/android-audio-backend
base:      main HEAD at the time of work start
```

**Branch ordering vs Phase 4 non-audio:** This worktree depends on
Phase 4 non-audio (`feature/android-compose-example` /
`worktree-android-compose-example`) for `SheetMusicAndroidJNI`,
`HandleTable`, `DrawProgram` serialization, and `Examples/Android/`.
The implementation plan starts only after Phase 4 non-audio merges to
`main`; until then this spec is committed to `main` but no code is
written.

If parallelism with Phase 4 non-audio is desired (i.e. start writing
this worktree before Phase 4 non-audio merges), the alternative is
to branch off `worktree-android-compose-example` and merge to `main`
after Phase 4 non-audio merges. Decision deferred to the plan.

## CLAUDE.md / docs updates (Plan scope)

- `CLAUDE.md` — Library layout section adds `Android/SheetMusicAudioAndroid/`
  Kotlin module entry. Android build section's "UI / PDF remain
  Apple-only pending Phase 4" sentence becomes "UI / PDF remain
  Apple-only; audio playback is delivered as a Kotlin Gradle module"
  with a pointer to this spec.
- Memory `project_android_port_roadmap` — Phase 4 audio entry
  updated to done state after merge; Phase 5 (loop / rate / export /
  Maven publication) noted as future.
- `Android/SheetMusicAudioAndroid/README.md` (new) — usage,
  `SoundfontResolver` Apple-Kotlin mapping table, ABI matrix.

## Risks

- **`fluidsynth-android` artifact lifetime.** A community fork could
  go unmaintained. Mitigation: the plan's first task vets, with a
  fallback to self-built `.aar` if needed. Long-term: Phase 5 may
  graduate to an in-repo NDK build of FluidSynth.
- **`fluid_player_seek` precision.** FluidSynth's seek may snap to
  the nearest tempo-track event rather than exact tick. If audible
  drift is observed on tap-to-seek, the plan adds a remediation task
  (manual all-notes-off + reschedule) and benchmarks.
- **JNI-thread cursor freshness during pause/seek bursts.** Polling
  at 30Hz could mis-report cursor on very fast seek sequences.
  Apple's `cursorTimer` has the same characteristic; documented as
  acceptable.
- **Compose composition reads on `StateFlow`** under heavy seek
  traffic can cause recomposition churn. Plan's manual smoke
  includes a stress run (10 seeks/sec) to confirm Compose doesn't
  drop frames.

## Alternative architectures considered (post-brainstorming refinement)

The brainstorming session picked **per-staff `fluid_synth_t`** for
mixer impl, on the (mistaken) basis that it removes a staff-count
limit. After spec self-review, this turns out to be untrue: the
`fluid_player` API has no per-track callback hook, so events from
multiple tracks must collide into a single 16-channel MIDI stream
regardless of how many `fluid_synth_t` instances exist. The 16-staff
ceiling applies either way.

Given the constraint is identical, **single `fluid_synth_t` with
channel-per-staff** would simplify the design:

- One `fluid_synth_t`, 16 channels.
- Per-staff volume → `fluid_synth_cc(synth, channel, 7, volume*127)`
  or `fluid_synth_set_gain` per channel (FluidSynth 2.x supports
  per-channel gain via `fluid_channel_set_gain` extension).
- Per-staff mute → `fluid_synth_all_notes_off(synth, channel)` +
  zero volume.
- One `fluid_synth_write_float` per audio callback instead of N.
- ~30% less Kotlin / FluidSynth boilerplate.

This spec preserves the brainstorming choice (per-staff
`fluid_synth_t`) and the plan executes against it, **but flags the
single-synth alternative as the immediate fallback if** during plan
execution any of the following are hit:

- Per-channel gain API on the chosen `fluidsynth-android` artifact is
  unavailable / broken → forces the single-synth path anyway.
- Memory benchmarks on dense scores exceed acceptable thresholds.
- Implementation complexity of per-staff routing via the playback
  callback exceeds 2 days of work.

The plan's task list explicitly includes a checkpoint after the
"vetting" task to confirm the per-staff architecture is viable
against the chosen artifact, with the single-synth pivot as the
documented fallback.

## Open questions deferred to the implementation plan

- Exact `fluidsynth-android` Maven coordinate and version.
- Whether to include the metronome's percussion SF2 alongside the
  example's main SF2 in `assets/`, or to expect the GM bank in the
  same SF2 to provide it.
- Whether to emit a single `MixerChannel` for the metronome (so
  Compose can render its slider alongside per-staff ones) or expose
  it via a separate API surface.
- Whether the round-trip golden binaries live under `Tests/SheetMusicTests/Resources/Golden/Audio/`
  (Swift convention) or `Android/SheetMusicAudioAndroid/src/test/resources/golden/`
  (Kotlin convention), with one location canonical and the other
  symlinked. Likely former, with a Gradle task copying into the
  Kotlin module's test resources.
