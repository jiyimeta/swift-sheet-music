# Android Engine Extensions (Phase 5 Sub-project A) — Design

**Status:** Spec — pending implementation
**Date:** 2026-05-20
**Owner:** kiichi
**Phase:** Android port, Phase 5 (deferred items)

## 1. Background

Phase 4 shipped `SheetMusicAudioAndroid` with FluidSynth + Oboe playback,
per-staff mixer, metronome, seek, skip, preview, and cursor tracking. Three
playback features that exist on the Apple side (`SheetMusicAudioApple.PlaybackEngine`)
were intentionally deferred to Phase 5:

- A-B loop region (`setLoop(from:to:)`, `setLoop(from:throughEndOf:)`, `clearLoop()`)
- Variable playback rate (`setRate(_:)`)
- Per-staff GM program change at runtime (`setProgram(forChannel:to:)`,
  `loadProgram(forStaff:program:)`, `MixerChannel.program: UInt8?`)

This sub-project ports those three to Android, brings the Compose demo app
up to parity with the Apple example for the same controls, and lays the
remaining Phase 5 items (audio file export, MediaSession, Maven Central,
armv7 ABI) aside as separate sub-projects.

Three other worktrees are in progress concurrently
(`worktree-layout-extraction`, `feature/playback-cursor-display`,
`worktree-loop-seek`). The first two touch Layout / UI / `LayoutBridge.swift`
and the JNI symbol file; the design below avoids those files. `worktree-loop-seek`
is inactive and confirmed safe to ignore.

## 2. Goals

- Android `AndroidPlaybackEngine` exposes the same loop / rate / program APIs
  as Apple `PlaybackEngine`, with the same semantics and the same no-op
  guard rails (`state == EXPORTING`, malformed inputs).
- Kotlin `MixerChannel` gains a `program: Int?` field mirroring
  `SheetMusicAudioCore.MixerChannel.program`.
- The Compose demo at `Examples/Android/` gains UI for all three: a rate
  slider, a GM program picker per staff in the mixer panel, and a tap-A/B
  loop overlay on the score canvas.
- JNI surface adds one new symbol (`nativeItemEndTick`); FluidSynth native
  bindings add one new entry (`playerSetTempo`).
- All existing tests still pass; new unit tests cover the new code paths.
- No source under any other in-flight worktree's edit set is touched.

## 3. Non-goals

- Apple-side `setRate` clamping. The spec records the future-work item but
  this sub-project does not change Apple code.
- A new `AudioBackend` protocol abstraction. Apple `PlaybackEngine` and
  Android `AndroidPlaybackEngine` continue to evolve in parallel without
  a shared protocol layer (deferred per Phase 3 deviation note in
  `project_android_port_roadmap.md`).
- Maven Central publication, armv7 ABI, MediaSession, audio file export.
  These are Phase 5 sub-projects B / C / D, each with its own spec.

## 4. API surface

### 4.1 `AndroidPlaybackEngine` (Kotlin)

New state flows:

```kotlin
val loopRange: StateFlow<LoopRange?>
val currentRate: StateFlow<Float>          // default 1.0
```

New methods:

```kotlin
fun setLoop(from: ScoreCursor, to: ScoreCursor)
fun setLoop(from: ScoreCursor, throughEndOf: ScoreItemID)
fun clearLoop()

fun setRate(rate: Float)

fun setStaffProgram(staffIndex: Int, program: Int)
```

All four methods are synchronous, thread-safe (StateFlow writes are atomic),
and no-op when `state.value == PlaybackState.EXPORTING`.

### 4.2 `MixerChannel` (Kotlin)

```kotlin
data class MixerChannel(
    val staffIndex: Int,
    val displayName: String,
    val volume: Float = 1.0f,
    val isMuted: Boolean = false,
    val isSoloed: Boolean = false,
    val effectiveMute: Boolean = false,
    val program: Int? = null,     // ← new; null for drum staves
)
```

`prepare(scoreHandle)` initializes `program` from the staff's initial
`StaffParams.program` for melodic staves and `null` for drum staves (mirrors
Apple `initialStaffProgram(at:in:)`).

### 4.3 `LoopRange` (Kotlin)

New file `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/LoopRange.kt`:

```kotlin
/** Mirrors SheetMusicAudioCore.LoopRange. Half-open [startTick, endTick). */
data class LoopRange(val startTick: Long, val endTick: Long)
```

### 4.4 New JNI symbol

```swift
@_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeItemEndTick")
public func nativeItemEndTick(
    env: UnsafeMutablePointer<JNIEnv?>, _: jclass, handle: jlong, idBytes: jbyteArray,
) -> jlong
```

Resolves a `ScoreItemID` byte payload (`ScoreItemIDCodec`-encoded) against
the timeline's `itemEndTicks` table. Returns `-1` if not found.

Lives in a new section of `Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift`
(append-only — avoids overlap with `feature/playback-cursor-display`'s
edits to `JNISymbols.swift` / `LayoutBridge.swift`).

Kotlin side adds `external fun nativeItemEndTick(handle: Long, idBytes: ByteArray): Long`
to `SheetMusicAudioJNI` and exposes it as `JniBridge.itemEndTick(scoreHandle, idBytes)`
with a `FakeJniBridge` shim for tests.

### 4.5 FluidSynth native binding

`FluidSynthNative.kt` adds:

```kotlin
external fun playerSetTempo(handle: Long, type: Int, value: Double): Int
```

Implemented in the existing C++ wrapper (`src/main/cpp/sheetmusicaudio_jni.cpp`
— filename verified at implementation time) by a thin call to
`fluid_player_set_tempo(player, type, value)`. The `type` argument is
`FLUID_PLAYER_TEMPO_INTERNAL` (`1`) for relative rate scaling; the type
constant is held in `PlayerDriver` and not exposed at the Kotlin layer.

`PlayerDriver` adds:

```kotlin
fun setTempo(scale: Double): Int
```

and a `NativeBindings.playerSetTempo` entry.

## 5. Semantics

### 5.1 Loop region

`AndroidPlaybackEngine` holds `loopRange: LoopRange?` state. The wrap is
host-driven, mirroring the Apple `tickCursor` approach (FluidSynth's own
`fluid_player_set_loop(player, n)` loops the entire SMF, not a sub-region —
unusable here).

**Wrap detection** runs inside `startPollJob` (the existing 33 ms cadence):

```
each poll iteration:
    tick = player.currentTick
    if loopRange != null && tick >= loopRange.endTick:
        fluidSynthEngine.allNotesOff()
        player.seekTick(loopRange.startTick)
        tick = loopRange.startTick
    // existing frame-decode + cursor update follows
```

**Snap-into-loop** on explicit position changes (`play(from:)` / `seek(to:)`):
a private helper `snapTickToLoop(tick: Long): Long` returns `loop.startTick`
when `tick` is outside the loop, else `tick` unchanged. Skip (`skip(seconds:)`)
also snaps.

**`currentTimeSeconds` fold:** when a loop is active, the polled raw tick can
briefly exceed `loop.endTick` between detection cycles. Wrap raw tick into
`[loop.startTick, loop.endTick)` with `loop.startTick + (raw - loop.startTick) % len`
before resolving to seconds — same fold as Apple `currentTimeSeconds`.

**API**:
- `setLoop(from: ScoreCursor, to: ScoreCursor)` — half-open `[from.tick, to.tick)`.
  No-op if either cursor doesn't resolve, or `from.tick >= to.tick`, or no
  player is prepared.
- `setLoop(from: ScoreCursor, throughEndOf: ScoreItemID)` — half-open
  `[from.tick, itemEndTick)`. No-op if cursor doesn't resolve, or
  `itemEndTick == -1`, or `from.tick >= itemEndTick`.
- `clearLoop()` — sets `loopRange.value = null`.

Loop range is cleared automatically on `prepare(scoreHandle)` (the timeline
that resolved its ticks is going away).

### 5.2 Playback rate

`AndroidPlaybackEngine` holds `pendingRate: Float = 1.0` and `currentRate`
StateFlow. `setRate(rate: Float)`:

1. No-op if `state == EXPORTING`.
2. Store `pendingRate = rate`.
3. If `playerDriver != null`: `playerDriver.setTempo(rate.toDouble())`.
4. Update `_currentRate.value = rate`.

`prepare(scoreHandle)` re-applies `pendingRate` after constructing the new
`PlayerDriver` so a rate set before `prepare` (or carried across `prepare`
calls) survives. Mirrors Apple `prepare` re-applying `pendingRate` to the
new sequencer.

No clamping at the engine layer. UI imposes a 0.5x–2.0x slider range;
out-of-range values from non-UI callers pass through to FluidSynth as-is.

### 5.3 Per-staff program change

`FluidSynthEngine` gains two pieces of state initialized in `setupStaves`:

```kotlin
private var loadedSfid: Int = -1
private val staffLoadParams = arrayOfNulls<StaffLoadParams>(16)
data class StaffLoadParams(val bankLSB: Int, val isDrums: Boolean)
```

`staffLoadParams[i]` is populated for every staff (drum and melodic) at
`setupStaves` time. New method:

```kotlin
fun setStaffProgram(staffIndex: Int, program: Int) {
    if (staffIndex !in 0 until staffCountValue) return
    val params = staffLoadParams[staffIndex] ?: return
    if (loadedSfid < 0) return
    val synth = this.synth ?: return
    val clamped = program.coerceIn(0, 127)
    synth.programSelect(
        sfid = loadedSfid,
        channel = staffIndex,
        bank = if (params.isDrums) 128 else params.bankLSB,
        program = clamped,
    )
}
```

`AndroidPlaybackEngine.setStaffProgram(staffIndex, program)`:

1. No-op if `state == EXPORTING`.
2. `fluidSynthEngine?.setStaffProgram(staffIndex, program)`.
3. `updateChannel(staffIndex) { it.copy(program = program) }`.

Mirroring Apple: the engine method itself does NOT gate on `isDrums`. Drum
staves are simply initialized with `program = null` in `MixerChannel`, and
the Compose UI hides the program picker when `channel.program == null`.
Programmatic callers can still set a drum-kit variation (selects a different
GM percussion kit within bank 128) — same constraint surface as Apple
`PlaybackEngine.loadProgram(forStaff:program:)`.

`prepare` initialization: after `staves = StaffParamsDecoder.decodeArray(...)`,
build the mixer channel list with `program = if (p.isDrums) null else p.program`.

### 5.4 EXPORTING state

Phase 5 sub-project B (audio file export) will introduce `PlaybackState.EXPORTING`
on Android. This spec's new APIs all gate on it preemptively so sub-project B
doesn't have to revisit them.

## 6. UI (Compose demo)

`Examples/Android/app/src/main/java/com/example/sheetmusic/`:

- **`AudioViewModel.kt`**: forward `setRate`, `setStaffProgram`, `setLoop*`,
  `clearLoop` to the engine. Expose `currentRate`, `loopRange`, `mixerChannels`
  as `StateFlow`s on the VM.
- **`AudioControls.kt`**: add a rate slider (0.5x to 2.0x, step 0.05,
  centered detent at 1.0x — Compose `Slider` with `steps = 30`,
  `valueRange = 0.5f..2.0f`).
- **`MixerPanel.kt`** (existing): each staff strip gets a clickable label
  "Program N" that opens `ProgramPicker.kt` (new — lazy column of 128
  GM patches loaded from a Kotlin `GMInstrument` enum mirroring
  `SheetMusicAudioCore.GMInstrument`). Drum staves show "Drums" non-clickable.
- **`ScoreView.kt`** + **`LoopSelectionOverlay.kt`** (new): a toggle button
  enters "loop select" mode. First tap on a note sets `loopStart`, second
  tap sets `loopEnd` and calls `setLoop(from: a, throughEndOf: bItemID)`.
  Third tap calls `clearLoop()` and exits mode. The selected range is drawn
  as a translucent rectangle covering the staff height between the two cursor
  positions. v0 visualization is coarse (single rectangle per system) —
  multi-system loop visual is a polish follow-up.

`GMInstrument` enum: 128 entries, name property mirroring the Apple enum.
The names are not pulled at runtime from Apple code — they are duplicated in
Kotlin (the list is closed and stable). The spec acknowledges the duplication;
extracting to a JSON resource shared at JNI is a future refactor.

## 7. Error handling

| Condition | Behavior |
|---|---|
| `state == EXPORTING` | All new APIs no-op |
| `setLoop(from:to:)` with cursor not in timeline | no-op |
| `setLoop(from:to:)` with `from.tick >= to.tick` | no-op |
| `setLoop(from:throughEndOf:)` with `nativeItemEndTick == -1` | no-op |
| `setRate` with negative or zero | passes through to FluidSynth (no clamp) |
| `setStaffProgram` out of `0..127` | clamped to range |
| `setStaffProgram` on drum staff | proceeds (selects a drum-kit variation within bank 128); UI hides picker so no end-user path |
| `setStaffProgram` before `prepare` | no-op (engine null) |
| `setLoop*` before `prepare` | no-op |

No exceptions are thrown from any of the new APIs. The poll loop's wrap path
catches throwables from `seekTick` defensively (existing pattern in
`teardownInternalNoCancelScopes`).

## 8. Testing

### 8.1 Kotlin JVM unit tests

`Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/`:

- **`AndroidPlaybackEngineLoopTest.kt`** — set a loop, advance `FakePlayerDriver.currentTick`
  past `endTick`, advance the poll dispatcher, assert `seekTick(startTick)` was
  called and `allNotesOff` fired. Cover both `setLoop` overloads with the
  `FakeJniBridge.itemEndTick` shim returning a known tick. Test `clearLoop`
  removes wrap behavior. Test `play(from:)` outside loop snaps. Test invalid
  inputs no-op.
- **`AndroidPlaybackEngineRateTest.kt`** — `setRate(2.0f)` invokes
  `FakePlayerDriver.setTempo(2.0)`. `setRate` before `prepare` then `prepare`
  re-applies the pending rate. `setRate` while `EXPORTING` is no-op.
  `currentRate` StateFlow updates.
- **`AndroidPlaybackEngineProgramTest.kt`** — `setStaffProgram(0, 24)` invokes
  `FakeSynthDriver.programSelect(sfid, 0, params.bankLSB, 24)` and updates
  `mixerChannels[0].program`. Drum staff: no-op + still null. Out-of-range
  clamps. Before `prepare`: no-op.
- **`FakePlayerDriver.kt`** — add `setTempo(scale: Double): Int` recording
  the calls.
- **`FakeJniBridge.kt`** — add `itemEndTick(scoreHandle, idBytes): Long` shim.
- **`FluidSynthEngineProgramTest.kt`** — extends existing `FluidSynthEngineTest`
  with `setStaffProgram` coverage on a mock `SynthDriver`.

### 8.2 Swift host tests

`Tests/SheetMusicTests/AndroidJNI/Audio/`:

- **`ItemEndTickBridgeTests.swift`** — parse a fixture score, compute its
  timeline, ask for `itemEndTicks[knownItemID]`, and assert the native
  bridge returns the same value. Negative case: an item not in the timeline
  returns `-1`.

### 8.3 Manual emulator smoke

Documented in `Examples/Android/SMOKE_TEST.md` (append a new section):

- Drop `~/Desktop/test.mscz` + GeneralUserGS, bundle, install.
- **Loop**: enter loop mode, tap two notes, hit play — verify section wraps.
- **Rate**: drag slider to 0.5x / 2.0x while playing — verify audible tempo
  change, cursor stays in sync.
- **Program**: tap a melodic-staff "Program N" label, pick a different patch
  (e.g., violin), verify next note plays new patch and prior notes unaffected.

### 8.4 Cross-platform regressions

`swift test` on macOS host (1196+ tests) must remain green. `swift build
--swift-sdk aarch64-unknown-linux-android28` for both library + tests must
remain clean. `:app:assembleDebug` builds the APK.

## 9. File-change inventory

### New files

```
Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/LoopRange.kt
Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/GMInstrument.kt
Android/SheetMusicAudioAndroid/src/test/kotlin/.../AndroidPlaybackEngineLoopTest.kt
Android/SheetMusicAudioAndroid/src/test/kotlin/.../AndroidPlaybackEngineRateTest.kt
Android/SheetMusicAudioAndroid/src/test/kotlin/.../AndroidPlaybackEngineProgramTest.kt
Android/SheetMusicAudioAndroid/src/test/kotlin/.../FluidSynthEngineProgramTest.kt
Examples/Android/app/src/main/java/com/example/sheetmusic/audio/ProgramPicker.kt
Examples/Android/app/src/main/java/com/example/sheetmusic/audio/LoopSelectionOverlay.kt
Tests/SheetMusicTests/AndroidJNI/Audio/ItemEndTickBridgeTests.swift
```

### Edited files

```
Android/SheetMusicAudioAndroid/src/main/kotlin/.../AndroidPlaybackEngine.kt
Android/SheetMusicAudioAndroid/src/main/kotlin/.../synth/FluidSynthEngine.kt
Android/SheetMusicAudioAndroid/src/main/kotlin/.../synth/PlayerDriver.kt
Android/SheetMusicAudioAndroid/src/main/kotlin/.../native/FluidSynthNative.kt
Android/SheetMusicAudioAndroid/src/main/kotlin/.../model/MixerChannel.kt
Android/SheetMusicAudioAndroid/src/main/cpp/sheetmusicaudio_jni.cpp  (filename verified during implementation)
Android/SheetMusicAudioAndroid/src/test/kotlin/.../fakes/FakePlayerDriver.kt
Android/SheetMusicAudioAndroid/src/test/kotlin/.../fakes/FakeJniBridge.kt
Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift           (append only)
Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioViewModel.kt
Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioControls.kt
Examples/Android/app/src/main/java/com/example/sheetmusic/audio/MixerPanel.kt
Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreView.kt
Examples/Android/SMOKE_TEST.md
```

Total: 9 new + ~14 edited. All edits sit outside the file sets of the
three in-flight worktrees.

## 10. Plan-level task breakdown

The implementation plan (next document) will split into roughly these tasks:

1. `nativeItemEndTick` JNI seam + Swift host test
2. cpp wrapper for `fluid_player_set_tempo` + Kotlin `playerSetTempo` binding
   + `PlayerDriver.setTempo` (+ `FakePlayerDriver` update)
3. `LoopRange.kt` + `MixerChannel.program` field + `GMInstrument.kt` enum
4. `FluidSynthEngine` `loadedSfid` / `staffLoadParams` + `setStaffProgram`
   + `FluidSynthEngineProgramTest`
5. `AndroidPlaybackEngine`: `loopRange` / `currentRate` StateFlows, the
   three loop APIs, `setRate`, `setStaffProgram`, poll-loop wrap, snap helper,
   `currentTimeSeconds` fold, EXPORTING guards, `pendingRate` re-apply in
   `prepare`. Three unit tests.
6. Compose UI — `AudioViewModel` forwarding, `AudioControls` rate slider,
   `MixerPanel` program label + `ProgramPicker`, `ScoreView` loop overlay
   + `LoopSelectionOverlay`.
7. Integration verification — macOS `swift test`, Android cross-compile +
   `:app:assembleDebug`, emulator manual smoke.
8. Doc + memory updates — `CLAUDE.md` Phase 5 status line, `SMOKE_TEST.md`,
   memory MEMORY.md / `project_android_port_roadmap.md`.

Each task is independent enough to dispatch as a subagent. Plan-author must
include absolute working-directory in each subagent prompt (lesson from
Phase 4 wayward-commit incident).

## 11. Future work (out of scope here, recorded for tracking)

- Apple-side `setRate` clamping (apply the Android UI's 0.5..2.0 range to
  Apple `PlaybackEngine.setRate` too, or document the divergence).
- `GMInstrument` deduplication: ship as a JSON resource read by both Swift
  and Kotlin, or as a JNI-served list.
- Multi-system loop visualization (draw a rectangle per intersected system
  rather than a single bounding rect).
- `setLoop(from:throughEndOf:)` for tuplet IDs / clef-change IDs — current
  spec covers note / rest items only because `itemEndTicks` only indexes
  those. Engagement with non-musical items is deferred.
- Audio file export (Phase 5 sub-project B) introduces `PlaybackState.EXPORTING`
  state on Android; the guards in this spec are forward-compatible.

## 12. Risks

- **Poll-loop precision**: wrap is ~33ms granular. A chord ringing into the
  wrap point gets cut off, identical to Apple. No mitigation planned — Apple
  ships this and it has not been a user complaint.
- **`fluid_player_set_tempo` type constant**: the integer value of
  `FLUID_PLAYER_TEMPO_INTERNAL` is verified against FluidSynth headers
  (`fluidsynth/midi.h`) at implementation time. Pinning the integer in
  Kotlin (`type = 1`) avoids re-binding a `<fluidsynth/midi.h>` enum but
  reads opaque — the cpp wrapper uses the symbolic name; the Kotlin layer
  uses the integer.
- **`programSelect` on bank 128 across SF2 boundaries**: changing a drum
  staff's program selects a different drum-kit variation within bank 128,
  not a melodic patch. The UI hides the picker for drum staves so users
  can't drive this; programmatic callers behave the same as on Apple.

## 13. References

- `Sources/SheetMusicAudioApple/PlaybackEngine.swift` — Apple parity reference
- `Sources/SheetMusicAudioApple/PlaybackEngine+Mixer.swift` — `setProgram` /
  `applyMixerState`
- `Sources/SheetMusicAudioCore/LoopRange.swift` — half-open semantics
- `Sources/SheetMusicAudioCore/MixerChannel.swift` — `program: UInt8?` field
- `Android/SheetMusicAudioAndroid/src/main/kotlin/.../AndroidPlaybackEngine.kt` —
  current Android engine
- FluidSynth `fluid_player_set_tempo` API (libfluidsynth headers in the
  VolcanoMobile .aar)
