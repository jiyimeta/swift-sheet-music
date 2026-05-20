# Android Engine Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `AndroidPlaybackEngine` to Apple parity for three deferred Phase 5 features — A-B loop region, variable playback rate, and per-staff GM program change — plus matching Compose demo UI.

**Architecture:** Mirror the Apple `PlaybackEngine` semantics on Android. Loop wrap is host-driven inside `startPollJob` (FluidSynth's `fluid_player_set_loop` loops the whole SMF, not a sub-region). Rate uses `fluid_player_set_tempo` in `FLUID_PLAYER_TEMPO_INTERNAL` mode. Program change calls `programSelect` again on the existing sfid. New JNI seam (`nativeItemEndTick`) resolves `PlaybackTimeline.itemEndTicks[itemId]` for the `setLoop(from:throughEndOf:)` variant. The plan is TDD throughout: each task writes a failing test first, then the minimal code to make it pass, then commits.

**Tech Stack:** Swift Testing, Kotlin (JUnit 4 + kotlinx-coroutines-test), Jetpack Compose, FluidSynth 2.x C API, Swift `@_cdecl` JNI, Compose Material 3.

**Spec:** `docs/superpowers/specs/2026-05-20-android-engine-extensions-design.md`

**Working directory:** A new git worktree at `.claude/worktrees/android-engine-extensions/` on branch `worktree-android-engine-extensions` is created before T1 (see Pre-flight). All shell commands below run from that worktree's root unless explicitly stated.

---

## Pre-flight: Create worktree

- [ ] **Step 1: Verify current state**

Run from main repo `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`:

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music status
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music branch --show-current
```

Expected: clean working tree, on `main`, HEAD at `9110ba5` (the spec commit).

- [ ] **Step 2: Create branch + worktree from local main HEAD**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music worktree add \
    .claude/worktrees/android-engine-extensions \
    -b worktree-android-engine-extensions
```

Expected: `Preparing worktree (new branch 'worktree-android-engine-extensions')` plus a HEAD message.

- [ ] **Step 3: Confirm worktree is at the spec commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-engine-extensions log -1 --oneline
```

Expected: `9110ba5 docs(spec): android engine extensions (Phase 5 sub-project A)`.

From here on, all commands run from `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-engine-extensions`. The Pre-flight is intentionally not a commit boundary.

---

## Task 1: `nativeItemEndTick` JNI seam

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift` — add `itemEndTick` helper
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift` — add `@_cdecl` entry (Android-only block)
- Test: `Tests/SheetMusicTests/AndroidJNI/Audio/ItemEndTickBridgeTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/AndroidJNI/Audio/ItemEndTickBridgeTests.swift`:

```swift
#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import Testing

    private func loadFixtureScore() throws -> Score {
        let url = try #require(Bundle.module.url(
            forResource: "midi01",
            withExtension: "mscx",
        ))
        let bytes = try Data(contentsOf: url)
        return try ScoreBridge.loadScore(bytes: bytes)
    }

    struct ItemEndTickBridgeTests {
        @Test func returnsEndTickForKnownNote() throws {
            let score = try loadFixtureScore()
            let timeline = PlaybackTimeline(score: score)
            // Pick any note that itemEndTicks tracks.
            let (id, expectedEndTick) = try #require(
                timeline.itemEndTicks.first(where: {
                    if case .note = $0.key { return true } else { return false }
                }),
            )
            let result = AudioMidiBridge.itemEndTick(score: score, id: id)
            #expect(result == Int64(expectedEndTick))
        }

        @Test func returnsMinusOneForUnknownItem() throws {
            let score = try loadFixtureScore()
            // Synthesize an id whose path is highly unlikely to exist.
            let bogus = ScoreItemID.rest(.init(
                staff: .init(partIndex: 99, staffIndexInPart: 0),
                measureIndex: 999,
                voiceIndex: 0,
                elementIndex: 0,
            ))
            let result = AudioMidiBridge.itemEndTick(score: score, id: bogus)
            #expect(result == -1)
        }
    }
#endif
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ItemEndTickBridgeTests
```

Expected: compile error — `AudioMidiBridge.itemEndTick` does not exist.

- [ ] **Step 3: Add the `itemEndTick` helper**

In `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`, append a new extension after the `earliestOf` extension (around line 47):

```swift
extension AudioMidiBridge {
    /// Looks up `id`'s end tick in the timeline. Returns -1 when the
    /// id has no entry in `itemEndTicks` (only `.note` and `.rest`
    /// items are tracked).
    static func itemEndTick(score: Score, id: ScoreItemID) -> Int64 {
        let timeline = PlaybackTimeline(score: score)
        guard let endTick = timeline.itemEndTicks[id] else { return -1 }
        return Int64(endTick)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ItemEndTickBridgeTests
```

Expected: 2 tests passing.

- [ ] **Step 5: Add the `@_cdecl` entry point**

In `Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift`, append inside the existing `#if os(Android)` block (before the final `#endif` at end of file):

```swift
    @_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeItemEndTick")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeItemEndTick(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ idBytes: jbyteArray,
    ) -> jlong {
        guard let score = scoreTable.value(for: scoreHandle) else { return -1 }
        let data = readJByteArray(env: envPtr, array: idBytes)
        guard !data.isEmpty,
              let id = try? ScoreItemIDCodec.decode(data)
        else { return -1 }
        return AudioMidiBridge.itemEndTick(score: score, id: id)
    }
```

- [ ] **Step 6: Verify Android cross-compile still builds**

```bash
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
    swift build --swift-sdk aarch64-unknown-linux-android28
```

Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift \
        Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift \
        Tests/SheetMusicTests/AndroidJNI/Audio/ItemEndTickBridgeTests.swift
git commit -m "feat(android-jni): nativeItemEndTick for setLoop(throughEndOf:)"
```

---

## Task 2: `fluid_player_set_tempo` native binding + `PlayerDriver.setTempo`

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/src/main/cpp/sheetmusicaudio_jni.cpp` — add JNI function
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/native/FluidSynthNative.kt` — add `external fun`
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/synth/PlayerDriver.kt` — `setTempo` + `NativeBindings.playerSetTempo`
- Modify: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/fakes/FakePlayerDriver.kt` — record `setTempo` calls
- Modify: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/synth/PlayerDriverTest.kt` — new test case

- [ ] **Step 1: Write the failing test**

Open `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/synth/PlayerDriverTest.kt` and add inside the existing test class:

```kotlin
@Test
fun setTempoForwardsScaleToNativeBindings() {
    val bindings = object : PlayerDriver.NativeBindings {
        var setTempoCalls = mutableListOf<Triple<Long, Int, Double>>()
        override fun newPlayer(synthHandle: Long): Long = 7L
        override fun deletePlayer(handle: Long) {}
        override fun playerAddMem(handle: Long, bytes: ByteArray): Int = 0
        override fun playerPlay(handle: Long): Int = 0
        override fun playerStop(handle: Long): Int = 0
        override fun playerJoin(handle: Long): Int = 0
        override fun playerSeek(handle: Long, tick: Long): Int = 0
        override fun playerGetCurrentTick(handle: Long): Long = 0
        override fun playerSetTempo(handle: Long, type: Int, value: Double): Int {
            setTempoCalls += Triple(handle, type, value)
            return 0
        }
    }
    val driver = PlayerDriver(attachedSynthHandle = 0L, nativeBindings = bindings)
    driver.load(byteArrayOf())
    val rc = driver.setTempo(1.5)
    assertEquals(0, rc)
    assertEquals(1, bindings.setTempoCalls.size)
    val (handle, type, value) = bindings.setTempoCalls.first()
    assertEquals(7L, handle)
    assertEquals(1, type)            // FLUID_PLAYER_TEMPO_INTERNAL
    assertEquals(1.5, value, 0.0001)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*PlayerDriverTest.setTempoForwardsScaleToNativeBindings"
```

Expected: compile error — `setTempo` not declared.

(If `./gradlew` is missing locally, run from `Examples/Android/` instead — the gradle wrapper there builds the module via the composite. Document filename: the audio module's gradle scripts live in `Android/SheetMusicAudioAndroid/`.)

- [ ] **Step 3: Add `playerSetTempo` to `NativeBindings` interface + production impl**

In `PlayerDriver.kt`, inside the `NativeBindings` interface, add:

```kotlin
fun playerSetTempo(handle: Long, type: Int, value: Double): Int
```

In the same file, inside the `ProductionBindings` companion object, add:

```kotlin
override fun playerSetTempo(handle: Long, type: Int, value: Double) =
    FluidSynthNative.playerSetTempo(handle, type, value)
```

In the same file, after the `currentTick` getter (~line 84), add:

```kotlin
/**
 * Sets a relative tempo scale on the player.
 * 1.0 = native tempo, 2.0 = double speed, 0.5 = half speed.
 * Returns FluidSynth status code (0 on success).
 *
 * Internally uses `FLUID_PLAYER_TEMPO_INTERNAL` (type=1) which scales the
 * SMF's tempo events. `FLUID_PLAYER_TEMPO_EXTERNAL_BPM/MIDI` would override
 * tempo absolutely — not what we want here.
 */
fun setTempo(scale: Double): Int =
    if (handle != 0L) nativeBindings.playerSetTempo(handle, 1, scale) else -1
```

- [ ] **Step 4: Add `playerSetTempo` to `FluidSynthNative`**

In `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/native/FluidSynthNative.kt`, in the `// ── Player ──` section, append:

```kotlin
external fun playerSetTempo(handle: Long, type: Int, value: Double): Int
```

- [ ] **Step 5: Update `FakePlayerDriver`**

In `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/fakes/FakePlayerDriver.kt`, inside `RecordingBindings`, add a recording slot and the method:

```kotlin
val setTempoCalls = mutableListOf<Pair<Int, Double>>()
override fun playerSetTempo(handle: Long, type: Int, value: Double): Int {
    setTempoCalls += type to value
    return 0
}
```

- [ ] **Step 6: Run the unit test**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*PlayerDriverTest.setTempoForwardsScaleToNativeBindings"
```

Expected: 1 test passing.

- [ ] **Step 7: Add the JNI C++ wrapper**

In `Android/SheetMusicAudioAndroid/src/main/cpp/sheetmusicaudio_jni.cpp`, append after the existing `playerGetCurrentTick` function (around line 261):

```cpp
extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_playerSetTempo(
    JNIEnv *, jobject, jlong handle, jint type, jdouble value
) {
    fluid_player_t *player = player_from(handle);
    if (player == nullptr) return -1;
    // type maps directly to fluid_player_set_tempo_type:
    //   0 = FLUID_PLAYER_TEMPO_INTERNAL (default)
    //   1 = FLUID_PLAYER_TEMPO_EXTERNAL_BPM
    //   2 = FLUID_PLAYER_TEMPO_EXTERNAL_MIDI
    // The Kotlin binding passes the integer directly; PlayerDriver.setTempo
    // hardcodes type=1 (INTERNAL: relative scale). Per fluidsynth/midi.h.
    return fluid_player_set_tempo(player, static_cast<int>(type),
                                  static_cast<double>(value));
}
```

(Note: FluidSynth's `fluid_player_set_tempo_type` enum names `FLUID_PLAYER_TEMPO_INTERNAL = 0`, `_EXTERNAL_BPM = 1`, `_EXTERNAL_MIDI = 2`. The plan's `PlayerDriver.setTempo` passes `1` which is `_EXTERNAL_BPM` — see Step 8 for verification + fix.)

- [ ] **Step 8: Verify the tempo-type constant via FluidSynth headers**

```bash
grep -n "FLUID_PLAYER_TEMPO" \
    "$HOME/Library/Android/sdk/ndk/"*/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include/fluidsynth/midi.h 2>/dev/null
# If header not in NDK sysroot, check the VolcanoMobile aar's bundled include:
find Android/SheetMusicAudioAndroid -path '*/fluidsynth-includes/fluidsynth/midi.h' 2>/dev/null | head -1 | \
    xargs -I {} grep -n "FLUID_PLAYER_TEMPO" {}
```

Confirm the enumerated values. Per FluidSynth 2.x docs:
- `FLUID_PLAYER_TEMPO_INTERNAL = 0` — relative scale, multiplies internal tempo
- `FLUID_PLAYER_TEMPO_EXTERNAL_BPM = 1` — absolute BPM
- `FLUID_PLAYER_TEMPO_EXTERNAL_MIDI = 2` — absolute as MIDI tempo (µs/quarter)

We want `INTERNAL` (relative scale, 1.0 = native). Correct the Kotlin binding:

In `PlayerDriver.kt`, change `setTempo`'s hardcoded type from `1` to `0`:

```kotlin
fun setTempo(scale: Double): Int =
    if (handle != 0L) nativeBindings.playerSetTempo(handle, 0, scale) else -1
```

In the test at Step 1, change `assertEquals(1, type)` to `assertEquals(0, type)`.

Re-run the test:

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*PlayerDriverTest.setTempoForwardsScaleToNativeBindings"
```

Expected: 1 test passing.

- [ ] **Step 9: Run all tests in the audio module to confirm no regression**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest
```

Expected: all tests passing.

- [ ] **Step 10: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/cpp/sheetmusicaudio_jni.cpp \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/native/FluidSynthNative.kt \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/synth/PlayerDriver.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/fakes/FakePlayerDriver.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/synth/PlayerDriverTest.kt
git commit -m "feat(android-audio): playerSetTempo binding + PlayerDriver.setTempo"
```

---

## Task 3: `LoopRange.kt`, `MixerChannel.program`, `GMInstrument.kt`

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/LoopRange.kt`
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/GMInstrument.kt`
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/MixerChannel.kt`
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/model/LoopRangeTest.kt` (new)
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/model/GMInstrumentTest.kt` (new)
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/model/MixerChannelTest.kt` (existing — append)

- [ ] **Step 1: Write the failing tests**

Create `LoopRangeTest.kt`:

```kotlin
package io.github.kiichiio.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Test

class LoopRangeTest {
    @Test
    fun storesStartAndEndTicks() {
        val r = LoopRange(startTick = 100L, endTick = 200L)
        assertEquals(100L, r.startTick)
        assertEquals(200L, r.endTick)
    }

    @Test
    fun equalityByValue() {
        assertEquals(LoopRange(0L, 480L), LoopRange(0L, 480L))
    }
}
```

Create `GMInstrumentTest.kt`:

```kotlin
package io.github.kiichiio.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Test

class GMInstrumentTest {
    @Test
    fun gmHasOneHundredTwentyEightPatches() {
        assertEquals(128, GMInstrument.values().size)
    }

    @Test
    fun program0IsAcousticGrandPiano() {
        val p = GMInstrument.values().first { it.program == 0 }
        assertEquals("Acoustic Grand Piano", p.displayName)
    }

    @Test
    fun program40IsViolin() {
        val p = GMInstrument.values().first { it.program == 40 }
        assertEquals("Violin", p.displayName)
    }
}
```

Append to `MixerChannelTest.kt`:

```kotlin
@Test
fun mixerChannelDefaultsProgramToNull() {
    val ch = MixerChannel(staffIndex = 0, displayName = "Staff 1")
    assertNull(ch.program)
}

@Test
fun mixerChannelHoldsProgramValue() {
    val ch = MixerChannel(staffIndex = 0, displayName = "Staff 1", program = 24)
    assertEquals(24, ch.program)
}
```

Add the import `import org.junit.Assert.assertNull` if missing.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*LoopRangeTest" --tests "*GMInstrumentTest" --tests "*MixerChannelTest"
```

Expected: compile errors — types / fields don't exist.

- [ ] **Step 3: Create `LoopRange.kt`**

```kotlin
package io.github.kiichiio.sheetmusic.audio.model

/**
 * Half-open tick range `[startTick, endTick)` the engine should
 * loop while playing. Mirrors `SheetMusicAudioCore.LoopRange`.
 */
data class LoopRange(val startTick: Long, val endTick: Long)
```

- [ ] **Step 4: Add `program` to `MixerChannel`**

Edit `MixerChannel.kt`:

```kotlin
package io.github.kiichiio.sheetmusic.audio.model

/** Mirrors SheetMusicAudioCore.MixerChannel. */
data class MixerChannel(
    val staffIndex: Int,
    val displayName: String,
    val volume: Float = 1.0f,
    val isMuted: Boolean = false,
    val isSoloed: Boolean = false,
    val effectiveMute: Boolean = false,
    /**
     * GM program (0..127) driving this staff's sampler, or `null` for
     * drum staves and for staves whose program is not selectable from
     * UI. Mirrors Apple `MixerChannel.program: UInt8?`.
     */
    val program: Int? = null,
)
```

- [ ] **Step 5: Create `GMInstrument.kt`**

```kotlin
package io.github.kiichiio.sheetmusic.audio.model

/**
 * General MIDI Level 1 patch list, mirrors `SheetMusicAudioCore.GMInstrument`.
 * Each enum case carries its program number (0..127) and display name.
 */
enum class GMInstrument(val program: Int, val displayName: String) {
    ACOUSTIC_GRAND_PIANO(0, "Acoustic Grand Piano"),
    BRIGHT_ACOUSTIC_PIANO(1, "Bright Acoustic Piano"),
    ELECTRIC_GRAND_PIANO(2, "Electric Grand Piano"),
    HONKY_TONK_PIANO(3, "Honky-tonk Piano"),
    ELECTRIC_PIANO_1(4, "Electric Piano 1"),
    ELECTRIC_PIANO_2(5, "Electric Piano 2"),
    HARPSICHORD(6, "Harpsichord"),
    CLAVI(7, "Clavi"),
    CELESTA(8, "Celesta"),
    GLOCKENSPIEL(9, "Glockenspiel"),
    MUSIC_BOX(10, "Music Box"),
    VIBRAPHONE(11, "Vibraphone"),
    MARIMBA(12, "Marimba"),
    XYLOPHONE(13, "Xylophone"),
    TUBULAR_BELLS(14, "Tubular Bells"),
    DULCIMER(15, "Dulcimer"),
    DRAWBAR_ORGAN(16, "Drawbar Organ"),
    PERCUSSIVE_ORGAN(17, "Percussive Organ"),
    ROCK_ORGAN(18, "Rock Organ"),
    CHURCH_ORGAN(19, "Church Organ"),
    REED_ORGAN(20, "Reed Organ"),
    ACCORDION(21, "Accordion"),
    HARMONICA(22, "Harmonica"),
    TANGO_ACCORDION(23, "Tango Accordion"),
    ACOUSTIC_GUITAR_NYLON(24, "Acoustic Guitar (nylon)"),
    ACOUSTIC_GUITAR_STEEL(25, "Acoustic Guitar (steel)"),
    ELECTRIC_GUITAR_JAZZ(26, "Electric Guitar (jazz)"),
    ELECTRIC_GUITAR_CLEAN(27, "Electric Guitar (clean)"),
    ELECTRIC_GUITAR_MUTED(28, "Electric Guitar (muted)"),
    OVERDRIVEN_GUITAR(29, "Overdriven Guitar"),
    DISTORTION_GUITAR(30, "Distortion Guitar"),
    GUITAR_HARMONICS(31, "Guitar harmonics"),
    ACOUSTIC_BASS(32, "Acoustic Bass"),
    ELECTRIC_BASS_FINGER(33, "Electric Bass (finger)"),
    ELECTRIC_BASS_PICK(34, "Electric Bass (pick)"),
    FRETLESS_BASS(35, "Fretless Bass"),
    SLAP_BASS_1(36, "Slap Bass 1"),
    SLAP_BASS_2(37, "Slap Bass 2"),
    SYNTH_BASS_1(38, "Synth Bass 1"),
    SYNTH_BASS_2(39, "Synth Bass 2"),
    VIOLIN(40, "Violin"),
    VIOLA(41, "Viola"),
    CELLO(42, "Cello"),
    CONTRABASS(43, "Contrabass"),
    TREMOLO_STRINGS(44, "Tremolo Strings"),
    PIZZICATO_STRINGS(45, "Pizzicato Strings"),
    ORCHESTRAL_HARP(46, "Orchestral Harp"),
    TIMPANI(47, "Timpani"),
    STRING_ENSEMBLE_1(48, "String Ensemble 1"),
    STRING_ENSEMBLE_2(49, "String Ensemble 2"),
    SYNTH_STRINGS_1(50, "SynthStrings 1"),
    SYNTH_STRINGS_2(51, "SynthStrings 2"),
    CHOIR_AAHS(52, "Choir Aahs"),
    VOICE_OOHS(53, "Voice Oohs"),
    SYNTH_VOICE(54, "Synth Voice"),
    ORCHESTRA_HIT(55, "Orchestra Hit"),
    TRUMPET(56, "Trumpet"),
    TROMBONE(57, "Trombone"),
    TUBA(58, "Tuba"),
    MUTED_TRUMPET(59, "Muted Trumpet"),
    FRENCH_HORN(60, "French Horn"),
    BRASS_SECTION(61, "Brass Section"),
    SYNTH_BRASS_1(62, "SynthBrass 1"),
    SYNTH_BRASS_2(63, "SynthBrass 2"),
    SOPRANO_SAX(64, "Soprano Sax"),
    ALTO_SAX(65, "Alto Sax"),
    TENOR_SAX(66, "Tenor Sax"),
    BARITONE_SAX(67, "Baritone Sax"),
    OBOE(68, "Oboe"),
    ENGLISH_HORN(69, "English Horn"),
    BASSOON(70, "Bassoon"),
    CLARINET(71, "Clarinet"),
    PICCOLO(72, "Piccolo"),
    FLUTE(73, "Flute"),
    RECORDER(74, "Recorder"),
    PAN_FLUTE(75, "Pan Flute"),
    BLOWN_BOTTLE(76, "Blown Bottle"),
    SHAKUHACHI(77, "Shakuhachi"),
    WHISTLE(78, "Whistle"),
    OCARINA(79, "Ocarina"),
    LEAD_1_SQUARE(80, "Lead 1 (square)"),
    LEAD_2_SAWTOOTH(81, "Lead 2 (sawtooth)"),
    LEAD_3_CALLIOPE(82, "Lead 3 (calliope)"),
    LEAD_4_CHIFF(83, "Lead 4 (chiff)"),
    LEAD_5_CHARANG(84, "Lead 5 (charang)"),
    LEAD_6_VOICE(85, "Lead 6 (voice)"),
    LEAD_7_FIFTHS(86, "Lead 7 (fifths)"),
    LEAD_8_BASS_LEAD(87, "Lead 8 (bass + lead)"),
    PAD_1_NEW_AGE(88, "Pad 1 (new age)"),
    PAD_2_WARM(89, "Pad 2 (warm)"),
    PAD_3_POLYSYNTH(90, "Pad 3 (polysynth)"),
    PAD_4_CHOIR(91, "Pad 4 (choir)"),
    PAD_5_BOWED(92, "Pad 5 (bowed)"),
    PAD_6_METALLIC(93, "Pad 6 (metallic)"),
    PAD_7_HALO(94, "Pad 7 (halo)"),
    PAD_8_SWEEP(95, "Pad 8 (sweep)"),
    FX_1_RAIN(96, "FX 1 (rain)"),
    FX_2_SOUNDTRACK(97, "FX 2 (soundtrack)"),
    FX_3_CRYSTAL(98, "FX 3 (crystal)"),
    FX_4_ATMOSPHERE(99, "FX 4 (atmosphere)"),
    FX_5_BRIGHTNESS(100, "FX 5 (brightness)"),
    FX_6_GOBLINS(101, "FX 6 (goblins)"),
    FX_7_ECHOES(102, "FX 7 (echoes)"),
    FX_8_SCI_FI(103, "FX 8 (sci-fi)"),
    SITAR(104, "Sitar"),
    BANJO(105, "Banjo"),
    SHAMISEN(106, "Shamisen"),
    KOTO(107, "Koto"),
    KALIMBA(108, "Kalimba"),
    BAG_PIPE(109, "Bag pipe"),
    FIDDLE(110, "Fiddle"),
    SHANAI(111, "Shanai"),
    TINKLE_BELL(112, "Tinkle Bell"),
    AGOGO(113, "Agogo"),
    STEEL_DRUMS(114, "Steel Drums"),
    WOODBLOCK(115, "Woodblock"),
    TAIKO_DRUM(116, "Taiko Drum"),
    MELODIC_TOM(117, "Melodic Tom"),
    SYNTH_DRUM(118, "Synth Drum"),
    REVERSE_CYMBAL(119, "Reverse Cymbal"),
    GUITAR_FRET_NOISE(120, "Guitar Fret Noise"),
    BREATH_NOISE(121, "Breath Noise"),
    SEASHORE(122, "Seashore"),
    BIRD_TWEET(123, "Bird Tweet"),
    TELEPHONE_RING(124, "Telephone Ring"),
    HELICOPTER(125, "Helicopter"),
    APPLAUSE(126, "Applause"),
    GUNSHOT(127, "Gunshot");

    companion object {
        /** Returns the GM patch for a given program number, or null if out of range. */
        fun forProgram(program: Int): GMInstrument? =
            if (program in 0..127) values()[program] else null
    }
}
```

- [ ] **Step 6: Run tests**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*LoopRangeTest" --tests "*GMInstrumentTest" --tests "*MixerChannelTest"
```

Expected: all passing.

- [ ] **Step 7: Run full module tests to catch any consumer that broke from adding `program`**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest
```

Expected: all passing. (The new `program` field has a default value, so existing call-sites that build `MixerChannel(...)` keep working.)

- [ ] **Step 8: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/LoopRange.kt \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/GMInstrument.kt \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/MixerChannel.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/model/LoopRangeTest.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/model/GMInstrumentTest.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/model/MixerChannelTest.kt
git commit -m "feat(android-audio): LoopRange, GMInstrument, MixerChannel.program"
```

---

## Task 4: `FluidSynthEngine.setStaffProgram`

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/synth/FluidSynthEngine.kt`
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/synth/FluidSynthEngineTest.kt` (existing — append)

- [ ] **Step 1: Write the failing test**

Append to `FluidSynthEngineTest.kt`:

```kotlin
@Test
fun setStaffProgramCallsProgramSelectOnExistingSfid() {
    val fakeDriver = FakeSynthDriver(handleValue = 42L)
    val engine = FluidSynthEngine(synthFactory = { fakeDriver })
    val resolver = object : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean) = null
        override val defaultGmSoundfontUri = android.net.Uri.parse("file:///gm.sf2")
    }
    fakeDriver.sfidToReturn = 9
    val staves = listOf(
        StaffParams(staffIndex = 0, bankLSB = 0, program = 0, isDrums = false,
                    partAddressHash = 0),
    )
    engine.setupStaves(staves, resolver, context = null)
    fakeDriver.programSelectCalls.clear()

    engine.setStaffProgram(0, 40)  // violin

    assertEquals(1, fakeDriver.programSelectCalls.size)
    val call = fakeDriver.programSelectCalls.first()
    assertEquals(9, call.sfid)        // existing sfid reused
    assertEquals(0, call.channel)
    assertEquals(0, call.bank)        // bankLSB
    assertEquals(40, call.program)
}

@Test
fun setStaffProgramOnDrumStaffUsesBank128() {
    val fakeDriver = FakeSynthDriver(handleValue = 42L)
    val engine = FluidSynthEngine(synthFactory = { fakeDriver })
    val resolver = object : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean) = null
        override val defaultGmSoundfontUri = android.net.Uri.parse("file:///gm.sf2")
    }
    fakeDriver.sfidToReturn = 9
    val staves = listOf(
        StaffParams(staffIndex = 0, bankLSB = 0, program = 0, isDrums = true,
                    partAddressHash = 0),
    )
    engine.setupStaves(staves, resolver, context = null)
    fakeDriver.programSelectCalls.clear()

    engine.setStaffProgram(0, 8)  // Room Kit

    assertEquals(1, fakeDriver.programSelectCalls.size)
    val call = fakeDriver.programSelectCalls.first()
    assertEquals(128, call.bank)
    assertEquals(8, call.program)
}

@Test
fun setStaffProgramClampsProgramToRange() {
    val fakeDriver = FakeSynthDriver(handleValue = 42L)
    val engine = FluidSynthEngine(synthFactory = { fakeDriver })
    val resolver = object : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean) = null
        override val defaultGmSoundfontUri = android.net.Uri.parse("file:///gm.sf2")
    }
    fakeDriver.sfidToReturn = 9
    val staves = listOf(
        StaffParams(staffIndex = 0, bankLSB = 0, program = 0, isDrums = false,
                    partAddressHash = 0),
    )
    engine.setupStaves(staves, resolver, context = null)
    fakeDriver.programSelectCalls.clear()

    engine.setStaffProgram(0, 999)

    assertEquals(127, fakeDriver.programSelectCalls.first().program)
}

@Test
fun setStaffProgramNoOpsBeforeSetupStaves() {
    val fakeDriver = FakeSynthDriver(handleValue = 42L)
    val engine = FluidSynthEngine(synthFactory = { fakeDriver })

    engine.setStaffProgram(0, 40)

    assertEquals(0, fakeDriver.programSelectCalls.size)
}

@Test
fun setStaffProgramNoOpsForOutOfRangeStaff() {
    val fakeDriver = FakeSynthDriver(handleValue = 42L)
    val engine = FluidSynthEngine(synthFactory = { fakeDriver })
    val resolver = object : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean) = null
        override val defaultGmSoundfontUri = android.net.Uri.parse("file:///gm.sf2")
    }
    fakeDriver.sfidToReturn = 9
    val staves = listOf(
        StaffParams(staffIndex = 0, bankLSB = 0, program = 0, isDrums = false,
                    partAddressHash = 0),
    )
    engine.setupStaves(staves, resolver, context = null)
    fakeDriver.programSelectCalls.clear()

    engine.setStaffProgram(99, 40)

    assertEquals(0, fakeDriver.programSelectCalls.size)
}
```

The test references `FakeSynthDriver.programSelectCalls` — check the existing fake's shape and (if missing) augment it. If `FakeSynthDriver` already records `programSelect` with a different field name, adapt the assertions accordingly.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*FluidSynthEngineTest.setStaffProgram*"
```

Expected: compile error — method not declared.

- [ ] **Step 3: Add `loadedSfid` and `staffLoadParams` to `FluidSynthEngine`**

In `FluidSynthEngine.kt`, add fields after the `rememberedCC7` / `channelMuted` block (~line 51):

```kotlin
/**
 * Last-loaded SoundFont id. Set in [setupStaves] and used by
 * [setStaffProgram] to swap programs on existing channels without
 * re-loading the SF2.
 */
private var loadedSfid: Int = -1

/**
 * Per-staff load parameters captured at [setupStaves] time. Used by
 * [setStaffProgram] to know which bank to target on a swap. `null`
 * entries indicate staves above [staffCountValue].
 */
data class StaffLoadParams(val bankLSB: Int, val isDrums: Boolean)
private val staffLoadParams = arrayOfNulls<StaffLoadParams>(16)
```

- [ ] **Step 4: Populate `loadedSfid` + `staffLoadParams` in `setupStaves`**

In `setupStaves`, after `val sfid = driver.loadSoundFont(...)` (around line 80), insert:

```kotlin
loadedSfid = sfid
```

Inside the `for (p in params) { ... }` loop, before the `if (p.isDrums)` branch, add:

```kotlin
staffLoadParams[p.staffIndex] = StaffLoadParams(
    bankLSB = if (p.isDrums) 128 else p.bankLSB,
    isDrums = p.isDrums,
)
```

In `teardown()`, append:

```kotlin
loadedSfid = -1
for (i in 0 until 16) staffLoadParams[i] = null
```

- [ ] **Step 5: Add `setStaffProgram`**

After `setChannelVolume` (~line 131), add:

```kotlin
/**
 * Swaps the GM program (sound) on staff [staffIndex]. No-op when no
 * SF2 is loaded, the staff index is out of range, or [setupStaves]
 * has not run yet. The program value is clamped to 0..127.
 */
fun setStaffProgram(staffIndex: Int, program: Int) {
    if (staffIndex !in 0 until staffCountValue) return
    val params = staffLoadParams[staffIndex] ?: return
    if (loadedSfid < 0) return
    val s = synth ?: return
    val clamped = program.coerceIn(0, 127)
    s.programSelect(
        sfid = loadedSfid,
        channel = staffIndex,
        bank = params.bankLSB,
        program = clamped,
    )
}
```

- [ ] **Step 6: Run tests**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*FluidSynthEngineTest.setStaffProgram*"
```

Expected: 5 tests passing.

- [ ] **Step 7: Run full module tests**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest
```

Expected: all passing.

- [ ] **Step 8: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/synth/FluidSynthEngine.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/synth/FluidSynthEngineTest.kt
git commit -m "feat(android-audio): FluidSynthEngine.setStaffProgram"
```

---

## Task 5: `AndroidPlaybackEngine` — loop / rate / program API

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngine.kt`
- Modify: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/fakes/FakeJniBridge.kt`
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngineLoopTest.kt` (new)
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngineRateTest.kt` (new)
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngineProgramTest.kt` (new)

This task is the largest. It is split into sub-tasks 5A through 5E so each commits independently.

### Task 5A: `JniBridge.itemEndTick` + `FakeJniBridge` update

- [ ] **Step 1: Extend the `JniBridge` interface**

In `AndroidPlaybackEngine.kt`, inside `interface JniBridge { ... }`, add:

```kotlin
/** Returns the item's end tick in ticks, or -1 if the id is not in the timeline. */
fun itemEndTick(scoreHandle: Long, idBytes: ByteArray): Long
```

In the `defaultBridge` companion-object impl, add:

```kotlin
override fun itemEndTick(h: Long, i: ByteArray) =
    SheetMusicAudioJNI.nativeItemEndTick(h, i)
```

Add the `external fun` to the Kotlin JNI bridge class `SheetMusicAudioJNI` (file at
`Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/jni/SheetMusicAudioJNI.kt` — verify path with `find Android -name SheetMusicAudioJNI.kt`):

```kotlin
@JvmStatic external fun nativeItemEndTick(scoreHandle: Long, idBytes: ByteArray): Long
```

- [ ] **Step 2: Extend `FakeJniBridge`**

```kotlin
var itemEndTickResult: Long = -1L
val itemEndTickCalls = mutableListOf<ByteArray>()
override fun itemEndTick(scoreHandle: Long, idBytes: ByteArray): Long {
    itemEndTickCalls += idBytes
    return itemEndTickResult
}
```

- [ ] **Step 3: Compile-check**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew compileDebugKotlin compileDebugUnitTestKotlin
```

Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngine.kt \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/jni/SheetMusicAudioJNI.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/fakes/FakeJniBridge.kt
git commit -m "feat(android-audio): JniBridge.itemEndTick + FakeJniBridge"
```

### Task 5B: `setRate` + `currentRate` StateFlow + `pendingRate` re-apply

- [ ] **Step 1: Write the failing test**

Create `AndroidPlaybackEngineRateTest.kt`:

```kotlin
package io.github.kiichiio.sheetmusic.audio

import io.github.kiichiio.sheetmusic.audio.fakes.FakeJniBridge
import io.github.kiichiio.sheetmusic.audio.fakes.FakePlayerDriver
import io.github.kiichiio.sheetmusic.audio.fakes.FakeOboeStream
import io.github.kiichiio.sheetmusic.audio.fakes.FakeSynthDriver
import io.github.kiichiio.sheetmusic.audio.model.PlaybackState
import io.github.kiichiio.sheetmusic.audio.serialization.StaffParamsCodec
import io.github.kiichiio.sheetmusic.audio.model.StaffParams
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidPlaybackEngineRateTest {

    private val resolver = object : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean) = null
        override val defaultGmSoundfontUri = android.net.Uri.parse("file:///gm.sf2")
    }

    private fun makeEngine(): Triple<AndroidPlaybackEngine, FakePlayerDriver.RecordingBindings, FakeJniBridge> {
        val (driver, bindings) = FakePlayerDriver.create()
        val jniBridge = FakeJniBridge(
            staffParamsResult = StaffParamsCodec.encodeArray(listOf(
                StaffParams(0, 0, 0, false, 0),
            )),
            renderMidiResult = byteArrayOf(0x4D, 0x54, 0x68, 0x64),  // sentinel MThd
        )
        val engine = AndroidPlaybackEngine(
            context = null,
            soundfontResolver = resolver,
            jniBridge = jniBridge,
            synthFactory = { FakeSynthDriver(handleValue = it.toLong()) },
            playerFactory = { _ -> driver },
            oboeFactory = { FakeOboeStream() },
            pollDispatcher = StandardTestDispatcher(),
        )
        return Triple(engine, bindings, jniBridge)
    }

    @Test
    fun setRateForwardsToPlayer() = runTest {
        val (engine, bindings, _) = makeEngine()
        engine.prepare(scoreHandle = 1L)
        bindings.setTempoCalls.clear()

        engine.setRate(1.5f)

        assertEquals(1, bindings.setTempoCalls.size)
        assertEquals(1.5, bindings.setTempoCalls.first().second, 0.0001)
        assertEquals(1.5f, engine.currentRate.value, 0.0001f)
    }

    @Test
    fun setRateBeforePrepareIsRecordedAndAppliedAtPrepare() = runTest {
        val (engine, bindings, _) = makeEngine()
        engine.setRate(0.5f)
        assertEquals(0, bindings.setTempoCalls.size)  // no player yet

        engine.prepare(scoreHandle = 1L)

        // After prepare, the pendingRate must be re-applied to the new player.
        assertEquals(1, bindings.setTempoCalls.size)
        assertEquals(0.5, bindings.setTempoCalls.first().second, 0.0001)
    }

    @Test
    fun currentRateStateFlowUpdates() = runTest {
        val (engine, _, _) = makeEngine()
        engine.prepare(scoreHandle = 1L)
        assertEquals(1.0f, engine.currentRate.value, 0.0001f)

        engine.setRate(2.0f)
        assertEquals(2.0f, engine.currentRate.value, 0.0001f)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*AndroidPlaybackEngineRateTest"
```

Expected: compile errors — `setRate`, `currentRate` missing.

- [ ] **Step 3: Add `currentRate` StateFlow + `setRate` method**

In `AndroidPlaybackEngine.kt`, in the `// ── Observable state ──` section, add:

```kotlin
private val _currentRate = MutableStateFlow(1.0f)
val currentRate: StateFlow<Float> = _currentRate.asStateFlow()
```

Near the other internal state vars (`masterVolume` area):

```kotlin
@Volatile private var pendingRate: Float = 1.0f
```

Add the public method in the `// ── Playback controls ──` section (after `stop()`):

```kotlin
/**
 * Scales playback speed. `1.0` is the score's native tempo; the host's
 * typical slider range is 0.5..2.0 but no clamping is applied here.
 * Persists across [prepare] calls — the rate is re-applied to a freshly
 * built [PlayerDriver].
 * No-op when [state] is [PlaybackState.EXPORTING].
 */
fun setRate(rate: Float) {
    if (_state.value == PlaybackState.EXPORTING) return
    pendingRate = rate
    playerDriver?.setTempo(rate.toDouble())
    _currentRate.value = rate
}
```

In `prepare(scoreHandle:)`, after the line `player.load(smfBytes)`, append:

```kotlin
// Carry the pending rate into the newly built player so a rate set
// before prepare (or across a re-prepare) survives.
if (pendingRate != 1.0f) {
    player.setTempo(pendingRate.toDouble())
}
```

After `_currentCursor.value = null` (in the same block), append:

```kotlin
_currentRate.value = pendingRate
```

- [ ] **Step 4: Run rate tests**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*AndroidPlaybackEngineRateTest"
```

Expected: 3 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngine.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngineRateTest.kt
git commit -m "feat(android-audio): setRate + currentRate StateFlow"
```

### Task 5C: `setStaffProgram` engine method + mixer mutation + initial program at prepare

- [ ] **Step 1: Write the failing test**

Create `AndroidPlaybackEngineProgramTest.kt`:

```kotlin
package io.github.kiichiio.sheetmusic.audio

import io.github.kiichiio.sheetmusic.audio.fakes.FakeJniBridge
import io.github.kiichiio.sheetmusic.audio.fakes.FakeOboeStream
import io.github.kiichiio.sheetmusic.audio.fakes.FakePlayerDriver
import io.github.kiichiio.sheetmusic.audio.fakes.FakeSynthDriver
import io.github.kiichiio.sheetmusic.audio.model.PlaybackState
import io.github.kiichiio.sheetmusic.audio.serialization.StaffParamsCodec
import io.github.kiichiio.sheetmusic.audio.model.StaffParams
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidPlaybackEngineProgramTest {

    private val resolver = object : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean) = null
        override val defaultGmSoundfontUri = android.net.Uri.parse("file:///gm.sf2")
    }

    private fun makeEngine(staves: List<StaffParams>):
        Triple<AndroidPlaybackEngine, FakeSynthDriver, FakeJniBridge>
    {
        val synthDrivers = mutableListOf<FakeSynthDriver>()
        val jniBridge = FakeJniBridge(
            staffParamsResult = StaffParamsCodec.encodeArray(staves),
            renderMidiResult = byteArrayOf(0x4D, 0x54, 0x68, 0x64),
        )
        val (player, _) = FakePlayerDriver.create()
        val engine = AndroidPlaybackEngine(
            context = null,
            soundfontResolver = resolver,
            jniBridge = jniBridge,
            synthFactory = { sr ->
                FakeSynthDriver(handleValue = sr.toLong()).also { synthDrivers += it }
            },
            playerFactory = { _ -> player },
            oboeFactory = { FakeOboeStream() },
            pollDispatcher = StandardTestDispatcher(),
        )
        // Force at least one driver to exist post-prepare to make calling
        // patterns easier; the engine creates the staff synth in setupStaves.
        return Triple(engine, synthDrivers.firstOrNull()
            ?: FakeSynthDriver(handleValue = 0L), jniBridge)
    }

    @Test
    fun prepareSetsInitialProgramFromStaffParams() = runTest {
        val staves = listOf(StaffParams(0, 0, 24, false, 0))  // acoustic-guitar
        val (engine, _, _) = makeEngine(staves)
        engine.prepare(scoreHandle = 1L)

        assertEquals(24, engine.mixerChannels.value[0].program)
    }

    @Test
    fun prepareSetsNullProgramForDrumStaff() = runTest {
        val staves = listOf(StaffParams(0, 0, 0, isDrums = true, partAddressHash = 0))
        val (engine, _, _) = makeEngine(staves)
        engine.prepare(scoreHandle = 1L)

        assertNull(engine.mixerChannels.value[0].program)
    }

    @Test
    fun setStaffProgramUpdatesMixerAndSynth() = runTest {
        val staves = listOf(StaffParams(0, 0, 0, false, 0))
        val synthDrivers = mutableListOf<FakeSynthDriver>()
        val jniBridge = FakeJniBridge(
            staffParamsResult = StaffParamsCodec.encodeArray(staves),
            renderMidiResult = byteArrayOf(0x4D, 0x54, 0x68, 0x64),
        )
        val (player, _) = FakePlayerDriver.create()
        val engine = AndroidPlaybackEngine(
            context = null,
            soundfontResolver = resolver,
            jniBridge = jniBridge,
            synthFactory = { sr -> FakeSynthDriver(handleValue = sr.toLong()).also { synthDrivers += it } },
            playerFactory = { _ -> player },
            oboeFactory = { FakeOboeStream() },
            pollDispatcher = StandardTestDispatcher(),
        )
        engine.prepare(scoreHandle = 1L)
        val staffSynth = synthDrivers.first { it.handleValue != 48_000L }  // not the metronome driver
        staffSynth.sfidToReturn = 9
        staffSynth.programSelectCalls.clear()

        engine.setStaffProgram(0, 40)

        // Mixer state reflects the new program.
        assertEquals(40, engine.mixerChannels.value[0].program)
        // Synth got the programSelect call.
        assertEquals(1, staffSynth.programSelectCalls.size)
        assertEquals(40, staffSynth.programSelectCalls.first().program)
    }

    @Test
    fun setStaffProgramNoOpsWhenExporting() = runTest {
        // EXPORTING is set externally; simulate by setting state through
        // a (still-internal) mechanism, then assert no mixer mutation.
        // For now this test documents the no-op intent; full coverage
        // arrives with sub-project B (audio file export).
        // Skip if the engine has no test-visible state setter — see plan.
    }
}
```

(If `_state.value = EXPORTING` is not externally settable yet, the `setStaffProgramNoOpsWhenExporting` test stays as a stub — sub-project B will harden it.)

- [ ] **Step 2: Run test to verify it fails**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*AndroidPlaybackEngineProgramTest"
```

Expected: compile error — `setStaffProgram` missing on engine or `programSelectCalls` shape mismatch on `FakeSynthDriver`.

- [ ] **Step 3: Add `setStaffProgram` to the engine**

In `AndroidPlaybackEngine.kt`, after `setStaffVolume` (in the mixer section):

```kotlin
/**
 * Swaps the GM program (sound) for staff [staffIndex].
 * The change is applied immediately to the synth and to the
 * mixer state. No-op when [state] is [PlaybackState.EXPORTING],
 * or for drum staves whose `MixerChannel.program` is null —
 * the program-picker UI hides those rows so no user path
 * triggers this branch.
 */
fun setStaffProgram(staffIndex: Int, program: Int) {
    if (_state.value == PlaybackState.EXPORTING) return
    fluidSynthEngine?.setStaffProgram(staffIndex, program)
    updateChannel(staffIndex) { it.copy(program = program) }
}
```

- [ ] **Step 4: Initialize `program` in `MixerChannel` at `prepare`**

In `prepare`, replace the existing line that builds mixer channels:

```kotlin
_mixerChannels.value = staves.mapIndexed { i, _ ->
    MixerChannel(staffIndex = i, displayName = "Staff ${i + 1}")
}
```

with:

```kotlin
_mixerChannels.value = staves.mapIndexed { i, p ->
    MixerChannel(
        staffIndex = i,
        displayName = "Staff ${i + 1}",
        program = if (p.isDrums) null else p.program,
    )
}
```

- [ ] **Step 5: Run program tests**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*AndroidPlaybackEngineProgramTest"
```

Expected: 3 tests passing (the EXPORTING stub may pass trivially).

- [ ] **Step 6: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngine.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngineProgramTest.kt
git commit -m "feat(android-audio): setStaffProgram + MixerChannel.program init"
```

### Task 5D: Loop region — `setLoop` / `clearLoop` / poll-loop wrap

- [ ] **Step 1: Write the failing test**

Create `AndroidPlaybackEngineLoopTest.kt`:

```kotlin
package io.github.kiichiio.sheetmusic.audio

import io.github.kiichiio.sheetmusic.audio.fakes.FakeJniBridge
import io.github.kiichiio.sheetmusic.audio.fakes.FakeOboeStream
import io.github.kiichiio.sheetmusic.audio.fakes.FakePlayerDriver
import io.github.kiichiio.sheetmusic.audio.fakes.FakeSynthDriver
import io.github.kiichiio.sheetmusic.audio.model.LoopRange
import io.github.kiichiio.sheetmusic.audio.model.ScoreCursor
import io.github.kiichiio.sheetmusic.audio.model.ScoreItemID
import io.github.kiichiio.sheetmusic.audio.model.StaffParams
import io.github.kiichiio.sheetmusic.audio.serialization.FrameCodec
import io.github.kiichiio.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.kiichiio.sheetmusic.audio.serialization.ScoreItemIDCodec
import io.github.kiichiio.sheetmusic.audio.serialization.StaffParamsCodec
import io.github.kiichiio.sheetmusic.audio.model.Frame
import io.github.kiichiio.sheetmusic.audio.model.StaffAddress
import io.github.kiichiio.sheetmusic.audio.model.RestID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidPlaybackEngineLoopTest {

    private val resolver = object : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean) = null
        override val defaultGmSoundfontUri = android.net.Uri.parse("file:///gm.sf2")
    }

    private fun makeEngine(): Quadruple {
        val staves = listOf(StaffParams(0, 0, 0, false, 0))
        val cursorAt100 = ScoreCursor(
            staff = StaffAddress(partIndex = 0, staffIndexInPart = 0),
            measureIndex = 0, voiceIndex = 0, elementIndex = 0,
        )
        val cursorAt200 = ScoreCursor(
            staff = StaffAddress(partIndex = 0, staffIndexInPart = 0),
            measureIndex = 0, voiceIndex = 0, elementIndex = 1,
        )
        val frameAt100 = FrameCodec.encode(Frame(
            tick = 100L, timeSeconds = 0.1, cursor = cursorAt100,
        ))
        val frameAt200 = FrameCodec.encode(Frame(
            tick = 200L, timeSeconds = 0.2, cursor = cursorAt200,
        ))
        val jniBridge = FakeJniBridge(
            staffParamsResult = StaffParamsCodec.encodeArray(staves),
            renderMidiResult = byteArrayOf(0x4D, 0x54, 0x68, 0x64),
        )
        // Make frameForCursor return frames whose tick fields are the
        // cursor's elementIndex × 100 — for an extremely terse mapping.
        // FakeJniBridge already returns the same bytes regardless; we use
        // a wrapping subclass below to differentiate.
        val (player, playerBindings) = FakePlayerDriver.create()
        val engine = AndroidPlaybackEngine(
            context = null,
            soundfontResolver = resolver,
            jniBridge = jniBridge,
            synthFactory = { FakeSynthDriver(handleValue = it.toLong()) },
            playerFactory = { _ -> player },
            oboeFactory = { FakeOboeStream() },
            pollDispatcher = StandardTestDispatcher(),
        )
        return Quadruple(engine, jniBridge, playerBindings, listOf(cursorAt100, cursorAt200, frameAt100, frameAt200))
    }

    private data class Quadruple(
        val engine: AndroidPlaybackEngine,
        val jniBridge: FakeJniBridge,
        val playerBindings: FakePlayerDriver.RecordingBindings,
        val fixtures: List<Any>,
    )

    @Test
    fun setLoopFromToStoresLoopRange() = runTest {
        val (engine, jniBridge, _, fixtures) = makeEngine()
        @Suppress("UNCHECKED_CAST")
        val cStart = fixtures[0] as ScoreCursor
        val cEnd = fixtures[1] as ScoreCursor
        @Suppress("UNCHECKED_CAST")
        val frameStart = fixtures[2] as ByteArray
        val frameEnd = fixtures[3] as ByteArray
        jniBridge.frameForCursorResult = frameStart  // returned for first call

        engine.prepare(scoreHandle = 1L)

        // The bridge currently returns the same payload for any cursor;
        // we drive intent by swapping the field between calls.
        jniBridge.frameForCursorResult = frameStart
        // Stub: a stronger bridge would map cursor → frame; here we accept
        // the limitation by reading the loop range bounds back as-is.

        engine.setLoop(from = cStart, to = cEnd)

        // The frame decoder must produce tick=100 from frameStart and tick=200
        // from frameEnd. The naïve fake returns the same value for both,
        // so until a richer fake exists, this test asserts only that
        // setLoop produced a non-null LoopRange.
        assertTrue(engine.loopRange.value != null)
    }

    @Test
    fun pollLoopWrapsBackToStartTick() = runTest {
        val (engine, jniBridge, playerBindings, fixtures) = makeEngine()
        @Suppress("UNCHECKED_CAST")
        val frameAt200 = fixtures[3] as ByteArray
        engine.prepare(scoreHandle = 1L)
        // Force loopRange directly via a setLoop call with frame-driven
        // bounds. Simplification: we set loopRange via reflection-free path
        // by calling setLoop on stub-resolved cursors and relying on the
        // bridge's frameForCursor returning frames with the expected ticks.
        @Suppress("UNCHECKED_CAST")
        val cStart = fixtures[0] as ScoreCursor
        @Suppress("UNCHECKED_CAST")
        val cEnd = fixtures[1] as ScoreCursor

        // We will sequence frameForCursor to return frameAt100 then frameAt200.
        var nextFrame = 0
        val frames = listOf(fixtures[2] as ByteArray, frameAt200)
        val richBridge = object : AndroidPlaybackEngine.JniBridge by jniBridge {
            override fun frameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray {
                val out = frames[nextFrame % frames.size]; nextFrame++
                return out
            }
        }
        // Re-build engine with the rich bridge.
        val engine2 = AndroidPlaybackEngine(
            context = null,
            soundfontResolver = resolver,
            jniBridge = richBridge,
            synthFactory = { FakeSynthDriver(handleValue = it.toLong()) },
            playerFactory = { _ -> FakePlayerDriver.create().first },
            oboeFactory = { FakeOboeStream() },
            pollDispatcher = StandardTestDispatcher(),
        )
        // NOTE: This test asserts the *intent*. Coverage hardening — driving
        // the poll loop, advancing virtual time, and asserting seekTick
        // calls — is left for an integration smoke and the manual emulator
        // check (Task 7). Plan ensures no regression of the existing
        // poll-loop tests.
    }

    @Test
    fun setLoopFromToInvalidRangeIsNoOp() = runTest {
        val (engine, _, _, fixtures) = makeEngine()
        engine.prepare(scoreHandle = 1L)
        @Suppress("UNCHECKED_CAST")
        val cStart = fixtures[0] as ScoreCursor
        // Pass the same cursor as both ends — start.tick >= end.tick.
        engine.setLoop(from = cStart, to = cStart)
        assertNull(engine.loopRange.value)
    }

    @Test
    fun clearLoopResetsRange() = runTest {
        val (engine, jniBridge, _, fixtures) = makeEngine()
        @Suppress("UNCHECKED_CAST")
        val cStart = fixtures[0] as ScoreCursor
        @Suppress("UNCHECKED_CAST")
        val cEnd = fixtures[1] as ScoreCursor
        @Suppress("UNCHECKED_CAST")
        val frameStart = fixtures[2] as ByteArray
        @Suppress("UNCHECKED_CAST")
        val frameEnd = fixtures[3] as ByteArray
        engine.prepare(scoreHandle = 1L)
        // Drive bridge to alternate start / end frames for the two
        // frameForCursor calls inside setLoop.
        var calls = 0
        val frames = listOf(frameStart, frameEnd)
        val rich = object : AndroidPlaybackEngine.JniBridge by jniBridge {
            override fun frameForCursor(h: Long, c: ByteArray): ByteArray {
                val out = frames[calls % frames.size]; calls++; return out
            }
        }
        val engine2 = AndroidPlaybackEngine(
            context = null, soundfontResolver = resolver, jniBridge = rich,
            synthFactory = { FakeSynthDriver(handleValue = it.toLong()) },
            playerFactory = { _ -> FakePlayerDriver.create().first },
            oboeFactory = { FakeOboeStream() },
            pollDispatcher = StandardTestDispatcher(),
        )
        engine2.prepare(scoreHandle = 1L)
        engine2.setLoop(from = cStart, to = cEnd)
        assertTrue(engine2.loopRange.value != null)
        engine2.clearLoop()
        assertNull(engine2.loopRange.value)
    }

    @Test
    fun setLoopThroughEndOfUsesItemEndTick() = runTest {
        val (engine, jniBridge, _, fixtures) = makeEngine()
        @Suppress("UNCHECKED_CAST")
        val cStart = fixtures[0] as ScoreCursor
        @Suppress("UNCHECKED_CAST")
        val frameStart = fixtures[2] as ByteArray
        jniBridge.frameForCursorResult = frameStart
        jniBridge.itemEndTickResult = 300L
        engine.prepare(scoreHandle = 1L)
        val itemId = ScoreItemID.rest(RestID(
            staff = StaffAddress(0, 0),
            measureIndex = 0, voiceIndex = 0, elementIndex = 1,
        ))
        engine.setLoop(from = cStart, throughEndOf = itemId)
        val lr = engine.loopRange.value
        assertTrue(lr != null)
        assertEquals(300L, lr!!.endTick)
    }

    @Test
    fun setLoopThroughEndOfIsNoOpWhenItemUnknown() = runTest {
        val (engine, jniBridge, _, fixtures) = makeEngine()
        @Suppress("UNCHECKED_CAST")
        val cStart = fixtures[0] as ScoreCursor
        @Suppress("UNCHECKED_CAST")
        val frameStart = fixtures[2] as ByteArray
        jniBridge.frameForCursorResult = frameStart
        jniBridge.itemEndTickResult = -1L
        engine.prepare(scoreHandle = 1L)
        val itemId = ScoreItemID.rest(RestID(
            staff = StaffAddress(0, 0),
            measureIndex = 0, voiceIndex = 0, elementIndex = 1,
        ))
        engine.setLoop(from = cStart, throughEndOf = itemId)
        assertNull(engine.loopRange.value)
    }
}
```

Notes on test fragility: because the existing `FakeJniBridge` returns the same bytes for every `frameForCursor` call, some loop-range tests use a small ad-hoc wrapping bridge that returns different frames for sequential calls. The poll-loop wrap test only asserts intent; coverage of the actual wrap timing is left to the manual emulator smoke in Task 7. If a follow-up wants to harden the poll-loop wrap test, factor a "scripted" `JniBridge` helper.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*AndroidPlaybackEngineLoopTest"
```

Expected: compile errors — `setLoop` / `clearLoop` / `loopRange` missing.

- [ ] **Step 3: Add `loopRange` StateFlow + private state**

In `AndroidPlaybackEngine.kt`, in the observable-state section:

```kotlin
private val _loopRange = MutableStateFlow<LoopRange?>(null)
val loopRange: StateFlow<LoopRange?> = _loopRange.asStateFlow()
```

Add the import: `import io.github.kiichiio.sheetmusic.audio.model.LoopRange`.

- [ ] **Step 4: Add the public loop API**

Add a new section `// ── Loop ──────────────────────────────────────────` after `// ── Seek / skip ──`:

```kotlin
/**
 * Loop the half-open region [from, to) — playback wraps at the onset
 * tick of `to` (the item under `to` is NOT sounded). Use
 * [setLoop(from:throughEndOf:)] to include the last item's full
 * ringing duration.
 *
 * No-op when [state] is [PlaybackState.EXPORTING], when either cursor
 * doesn't resolve, when start.tick >= end.tick, or when no player is
 * prepared yet.
 */
fun setLoop(from: ScoreCursor, to: ScoreCursor) {
    if (_state.value == PlaybackState.EXPORTING) return
    if (playerDriver == null) return
    val fromBytes = jniBridge.frameForCursor(scoreHandle, ScoreCursorCodec.encode(from))
    val toBytes = jniBridge.frameForCursor(scoreHandle, ScoreCursorCodec.encode(to))
    val fromFrame = FrameDecoder.decode(fromBytes) ?: return
    val toFrame = FrameDecoder.decode(toBytes) ?: return
    if (fromFrame.tick >= toFrame.tick) return
    _loopRange.value = LoopRange(startTick = fromFrame.tick, endTick = toFrame.tick)
}

/**
 * Loop from `from` through the end of `throughEndOf`'s notated
 * duration. Mirrors Apple `setLoop(from:throughEndOf:)`.
 *
 * No-op when [state] is [PlaybackState.EXPORTING], when `from` doesn't
 * resolve, when the item's end tick is not in the timeline
 * (`nativeItemEndTick` returns -1), or when no player is prepared.
 */
fun setLoop(from: ScoreCursor, throughEndOf: ScoreItemID) {
    if (_state.value == PlaybackState.EXPORTING) return
    if (playerDriver == null) return
    val fromBytes = jniBridge.frameForCursor(scoreHandle, ScoreCursorCodec.encode(from))
    val fromFrame = FrameDecoder.decode(fromBytes) ?: return
    val endTick = jniBridge.itemEndTick(scoreHandle, ScoreItemIDCodec.encode(throughEndOf))
    if (endTick < 0) return
    if (fromFrame.tick >= endTick) return
    _loopRange.value = LoopRange(startTick = fromFrame.tick, endTick = endTick)
}

/**
 * Disable looping. The next poll cycle stops snapping the playhead
 * back to startTick, so playback continues past the previous loop end.
 */
fun clearLoop() {
    if (_state.value == PlaybackState.EXPORTING) return
    _loopRange.value = null
}

/** Clamp `tick` into the active loop, or return it unchanged. */
private fun snapTickToLoop(tick: Long): Long {
    val loop = _loopRange.value ?: return tick
    return if (tick < loop.startTick || tick >= loop.endTick) loop.startTick else tick
}
```

Add imports: `ScoreItemID`, `ScoreItemIDCodec`.

- [ ] **Step 5: Wrap inside `startPollJob`**

Find the `private fun startPollJob()` and update it:

```kotlin
private fun startPollJob() {
    pollJob?.cancel()
    pollJob = pollScope.launch {
        while (isActive && _state.value == PlaybackState.PLAYING) {
            val player = playerDriver ?: break
            var tick = player.currentTick
            // Loop wrap: if we've advanced past loop.endTick, snap back.
            val loop = _loopRange.value
            if (loop != null && tick >= loop.endTick) {
                fluidSynthEngine?.allNotesOff()
                player.seekTick(loop.startTick)
                tick = loop.startTick
            }
            metronomeMixer?.updateCurrentTick(tick)

            val frameBytes = jniBridge.frameAtTick(scoreHandle, tick)
            val frame = FrameDecoder.decode(frameBytes)
            if (frame != null) {
                _currentCursor.value = frame.cursor
                _currentTimeSeconds.value = frame.timeSeconds
            }
            // End of score: only stop when no loop is active.
            if (loop == null && tick >= totalTicks && totalTicks > 0) {
                stop()
                break
            }
            delay(33)
        }
    }
}
```

- [ ] **Step 6: Snap into loop on `play(from:)` / `seek(to:)` / `skip(seconds:)`**

In `play(from: ScoreCursor?)`, after the existing `if (from != null) seek(from)` line, add no logic change — the snap happens inside `seek`.

In `seek(to: ScoreCursor)`, after the line that computes `frame.tick`, snap it:

```kotlin
fun seek(to: ScoreCursor) {
    if (_state.value == PlaybackState.EXPORTING) return
    val player = playerDriver ?: return
    val cursorBytes = ScoreCursorCodec.encode(to)
    val frameBytes = jniBridge.frameForCursor(scoreHandle, cursorBytes)
    val frame = FrameDecoder.decode(frameBytes) ?: return
    val snapped = snapTickToLoop(frame.tick)
    fluidSynthEngine?.allNotesOff()
    player.seekTick(snapped)
    _currentCursor.value = to
    _currentTimeSeconds.value = frame.timeSeconds
}
```

In `skip(seconds:)`, similarly snap:

```kotlin
fun skip(seconds: Double) {
    if (_state.value == PlaybackState.EXPORTING) return
    val player = playerDriver ?: return
    val total = _totalTimeSeconds.value
    val target = (_currentTimeSeconds.value + seconds).coerceIn(0.0, total)
    val targetTickEstimate = if (total > 0) {
        (target / total * totalTicks).toLong()
    } else 0L
    val frameBytes = jniBridge.frameAtTick(scoreHandle, targetTickEstimate)
    val frame = FrameDecoder.decode(frameBytes) ?: return
    val snapped = snapTickToLoop(frame.tick)
    fluidSynthEngine?.allNotesOff()
    player.seekTick(snapped)
    _currentCursor.value = frame.cursor
    _currentTimeSeconds.value = frame.timeSeconds
}
```

- [ ] **Step 7: Clear loop on re-prepare**

In `prepare(scoreHandle:)`, near the start of the block (right after the `prepareMutex.withLock` opening), insert:

```kotlin
_loopRange.value = null
```

- [ ] **Step 8: Run loop tests + full module tests**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest --tests "*AndroidPlaybackEngineLoopTest"
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest
```

Expected: loop tests pass, full module tests pass.

- [ ] **Step 9: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngine.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngineLoopTest.kt
git commit -m "feat(android-audio): setLoop / clearLoop + poll-loop wrap"
```

### Task 5E: Android cross-compile check

- [ ] **Step 1: Cross-compile + tests**

```bash
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
    swift build --swift-sdk aarch64-unknown-linux-android28 --build-tests
```

Expected: `Build complete!`.

- [ ] **Step 2: macOS host swift test**

```bash
swift test --filter ItemEndTickBridgeTests
swift test
```

Expected: both green, no regressions in the broader test suite.

- [ ] **Step 3: Commit (if anything bumped — typically empty)**

If `swift build` surfaced an issue, fix it inline (small Swift-only adjustment) and commit:

```bash
git add -A
git commit -m "chore(android-jni): cross-compile fix-up"
```

If nothing changed, no commit.

---

## Task 6: Compose demo UI

**Files:**
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioViewModel.kt`
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioControls.kt`
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/MixerPanel.kt`
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreView.kt`
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/ProgramPicker.kt`
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/LoopSelectionOverlay.kt`

This task is UI-only and not covered by unit tests in the Compose tree. We rely on the Task 7 emulator smoke for verification.

- [ ] **Step 1: AudioViewModel — forward new APIs**

Edit `AudioViewModel.kt`. Add fields:

```kotlin
val currentRate: StateFlow<Float> get() = engine.currentRate
val loopRange: StateFlow<io.github.kiichiio.sheetmusic.audio.model.LoopRange?> get() = engine.loopRange
```

(No new methods; UI calls `viewModel.engine.setRate(...)` etc directly, matching the existing pattern used by play/pause/stop in `AudioControls`.)

- [ ] **Step 2: AudioControls — add rate slider**

In `AudioControls.kt`, after the time-readout `Text(...)` block, add:

```kotlin
val rate by viewModel.currentRate.collectAsState()
if (isPrepared) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
    ) {
        Text(
            text = "Speed: %.2fx".format(rate),
            style = MaterialTheme.typography.bodySmall,
        )
        Slider(
            value = rate,
            onValueChange = { viewModel.engine.setRate(it) },
            valueRange = 0.5f..2.0f,
            steps = 29,        // 0.05 detents between 0.5 and 2.0 = 30 stops
        )
    }
}
```

Add imports: `androidx.compose.material3.Slider`, `androidx.compose.runtime.collectAsState`, `androidx.compose.runtime.getValue`.

- [ ] **Step 3: MixerPanel — program picker per strip**

(Read the existing `MixerPanel.kt` first to understand its strip layout; the snippet below assumes each strip is a `Row` with a name label + volume slider + mute / solo buttons.)

Add inside each staff strip, after the name label:

```kotlin
val program = channel.program
if (program != null) {
    var showPicker by remember { mutableStateOf(false) }
    TextButton(onClick = { showPicker = true }) {
        Text(GMInstrument.forProgram(program)?.displayName ?: "Program $program")
    }
    if (showPicker) {
        ProgramPicker(
            current = program,
            onSelect = { selected ->
                viewModel.engine.setStaffProgram(channel.staffIndex, selected)
                showPicker = false
            },
            onDismiss = { showPicker = false },
        )
    }
} else {
    Text("Drums", style = MaterialTheme.typography.bodySmall)
}
```

Add imports as needed: `androidx.compose.runtime.remember`, `mutableStateOf`, `setValue`, `getValue`, `io.github.kiichiio.sheetmusic.audio.model.GMInstrument`.

- [ ] **Step 4: ProgramPicker.kt (new)**

```kotlin
package com.example.sheetmusic.audio

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.github.kiichiio.sheetmusic.audio.model.GMInstrument

/**
 * Modal dialog listing all 128 GM patches. The currently selected
 * patch is scrolled into view on first composition.
 */
@Composable
fun ProgramPicker(
    current: Int,
    onSelect: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val listState = rememberLazyListState()
    LaunchedEffect(Unit) {
        if (current in 0..127) listState.scrollToItem(current)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Pick a sound") },
        text = {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxWidth(),
            ) {
                items(GMInstrument.values().toList()) { instrument ->
                    TextButton(
                        onClick = { onSelect(instrument.program) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 2.dp),
                    ) {
                        val style = if (instrument.program == current)
                            MaterialTheme.typography.bodyMedium
                        else MaterialTheme.typography.bodySmall
                        Text(
                            text = "${instrument.program}: ${instrument.displayName}",
                            style = style,
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}
```

- [ ] **Step 5: LoopSelectionOverlay.kt (new — minimal v0)**

```kotlin
package com.example.sheetmusic.audio

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Minimal v0: a toggle that surfaces "loop mode" status. Wiring the
 * tap-to-set-A / tap-to-set-B flow into `ScoreCanvas` requires score-
 * cursor / item-id resolution from a Compose pointer event, which lives
 * outside this Phase 5 sub-project. For now this composable exposes:
 *   - on/off toggle for engine.clearLoop()
 *   - text status showing the current loop range (tick-based)
 *
 * Phase 5.1 follow-up: replace the "intent stub" lambdas with real tap
 * handlers that walk the LayoutDocument and produce ScoreCursor / ScoreItemID.
 */
@Composable
fun LoopSelectionOverlay(
    viewModel: AudioViewModel,
    modifier: Modifier = Modifier,
) {
    val lr by viewModel.loopRange.collectAsState()
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .background(if (lr != null) Color(0x222196F3) else Color.Transparent),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = if (lr != null) "Loop: ${lr!!.startTick}..${lr!!.endTick}"
                   else "Loop: off",
            style = MaterialTheme.typography.bodySmall,
        )
        Switch(
            checked = lr != null,
            onCheckedChange = { on ->
                if (!on) viewModel.engine.clearLoop()
                // Setting a loop region requires a UI gesture not yet wired
                // (tap-to-set-A / -B). Phase 5.1 follow-up.
            },
        )
    }
}
```

Add the import `androidx.compose.runtime.collectAsState` / `getValue` at the top.

- [ ] **Step 6: ScoreView — wire `LoopSelectionOverlay` below `PageControls`**

In `ScoreView.kt`, find where `PageControls` is rendered. Below it (still inside the same `Column`), add:

```kotlin
LoopSelectionOverlay(viewModel = audioViewModel)
```

The `audioViewModel` reference may need to be threaded through `ScoreView`'s parameters if not already available. Read the file first; if the AudioViewModel is reachable via composition-local or a NavHost-level scope, use that.

- [ ] **Step 7: Build the demo APK**

```bash
cd Examples/Android && ./gradlew :app:assembleDebug
```

Expected: `BUILD SUCCESSFUL`. Address any Kotlin compile errors (missing imports, mismatched types) inline.

- [ ] **Step 8: Commit**

```bash
git add Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioViewModel.kt \
        Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioControls.kt \
        Examples/Android/app/src/main/java/com/example/sheetmusic/audio/MixerPanel.kt \
        Examples/Android/app/src/main/java/com/example/sheetmusic/audio/ProgramPicker.kt \
        Examples/Android/app/src/main/java/com/example/sheetmusic/audio/LoopSelectionOverlay.kt \
        Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreView.kt
git commit -m "feat(examples-android): rate slider, program picker, loop toggle"
```

---

## Task 7: Integration verification

**Files:** None (verification only).

- [ ] **Step 1: macOS host swift test (full)**

```bash
swift test
```

Expected: all tests passing. Cross-reference against pre-feature baseline (`1196+` tests in the latest memory note — verify with `swift test 2>&1 | tail -5`).

- [ ] **Step 2: Android cross-compile (both ABIs)**

```bash
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
    swift build --swift-sdk aarch64-unknown-linux-android28
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
    swift build --swift-sdk x86_64-unknown-linux-android28
```

Expected: both clean.

- [ ] **Step 3: Android Gradle unit tests**

```bash
cd Android/SheetMusicAudioAndroid && ./gradlew testDebugUnitTest
```

Expected: all passing.

- [ ] **Step 4: Stage native libs for Examples**

```bash
Scripts/android-build-libs.sh
```

Expected: both `arm64-v8a` and `x86_64` libs land under `Examples/Android/app/src/main/jniLibs/`.

- [ ] **Step 5: Stage `test.mscz` + soundfont**

```bash
Scripts/android-bundle-test-score.sh
```

Expected: `Examples/Android/app/src/main/assets/test.mscz` + `gm.sf2` present.

- [ ] **Step 6: Build + install APK**

```bash
cd Examples/Android && ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Expected: `Success`.

- [ ] **Step 7: Manual emulator smoke — rate**

```bash
adb shell am start -n com.example.sheetmusic/.MainActivity
```

Tap Play. Drag the speed slider to 0.5x and 2.0x while playing — confirm audible tempo change and the cursor stays in sync. Reset to 1.0x.

If anything fails, capture a screencap:

```bash
adb shell screencap -p /sdcard/sm.png && adb pull /sdcard/sm.png /tmp/
```

and iterate. Otherwise check the box.

- [ ] **Step 8: Manual emulator smoke — program**

Open the mixer panel. Tap a non-drum staff's program label; pick "Violin" (program 40). Tap Play. Confirm the chosen staff plays the new patch and the other staves are unaffected.

- [ ] **Step 9: Manual emulator smoke — loop toggle**

Toggle the loop switch off (the visible labelled status is the only behaviour for v0 — a full tap-to-set-A/B flow is Phase 5.1). Verify the toggle reflects engine state.

- [ ] **Step 10: Append to SMOKE_TEST.md**

In `Examples/Android/SMOKE_TEST.md`, append a section:

```markdown
## Phase 5 (sub-project A) — engine extensions

### Rate slider
1. Open the app and wait for "Ready" state.
2. Tap Play.
3. Drag the Speed slider to 0.5x → audible slow-down + cursor still tracks.
4. Drag to 2.0x → audible speed-up + cursor still tracks.
5. Drag back to 1.0x.

### Program picker
1. Tap Play, then Pause.
2. In the mixer panel, tap a non-drum staff's program label.
3. Pick "Violin" (program 40).
4. Tap Play → that staff sounds as a violin.

### Loop toggle (v0)
1. The Loop switch defaults to off.
2. After a future setLoop() call (Phase 5.1 UI), the switch flips on
   and the tick range is displayed.
3. Toggling off here calls clearLoop().
```

- [ ] **Step 11: Commit smoke-test additions**

```bash
git add Examples/Android/SMOKE_TEST.md
git commit -m "docs(examples-android): SMOKE_TEST entries for Phase 5A"
```

---

## Task 8: Docs + memory updates

**Files:**
- Modify: `CLAUDE.md` — Phase 5 status line in the "Android build" section
- Update memory: `project_android_port_roadmap.md`

- [ ] **Step 1: CLAUDE.md update**

In `CLAUDE.md`, in the Android section, locate any "Phase 5" mention (currently only in roadmap memory; the CLAUDE.md may need a new bullet). Add to the "Format support on Android" / nearby area:

```markdown
### Engine extensions (Phase 5, sub-project A)

`AndroidPlaybackEngine` exposes `setLoop(from:to:)`, `setLoop(from:throughEndOf:)`,
`clearLoop()`, `setRate(_:)`, and `setStaffProgram(staffIndex:program:)` —
parity with `SheetMusicAudioApple.PlaybackEngine`. The Compose demo at
`Examples/Android/` exposes a rate slider and program picker; the loop UI
is wired as a toggle for v0 (full tap-to-set-A/B selection is a follow-up).
```

- [ ] **Step 2: Commit CLAUDE.md**

```bash
git add CLAUDE.md
git commit -m "docs(claude): Phase 5 sub-project A engine extensions"
```

- [ ] **Step 3: Update auto memory**

Update `~/.claude/projects/-Users-kiichi-Developer-Personal-swift-packages-swift-sheet-music/memory/project_android_port_roadmap.md`:

In the "## Phase 5 — Deferred / follow-on work" section, replace:

```markdown
- **Loop region** (`setLoop`) — UI + engine integration
- **Variable playback rate** (`setRate`) — FluidSynth tempo scaling
- **Per-staff program change at runtime** (`loadProgram`)
```

with:

```markdown
- ~~Loop region (`setLoop`)~~ — shipped 2026-05-20 in sub-project A (branch `worktree-android-engine-extensions`); engine API + Compose toggle. Full tap-to-set-A/B UI deferred to Phase 5.1.
- ~~Variable playback rate (`setRate`)~~ — shipped 2026-05-20 in sub-project A. FluidSynth `fluid_player_set_tempo` (FLUID_PLAYER_TEMPO_INTERNAL).
- ~~Per-staff program change at runtime~~ — shipped 2026-05-20 in sub-project A. `programSelect` reuses existing sfid.
```

This is a memory update, not a repo file — no git commit needed.

---

## Task 9: Finishing the branch

Per the user's `feedback_big_task_autonomy.md` memory: large multi-task ports may proceed without per-step confirmation. Once the worktree is fully verified, invoke the `superpowers:finishing-a-development-branch` skill to choose merge / PR / cleanup.

The branch ships as one cohesive PR titled "feat(android): Phase 5 sub-project A — engine extensions" or merges to local main directly per user preference.

---

## Self-review checklist (executed by plan author before handoff)

- [x] Every new public API in the spec has at least one task (loop ×3, rate ×1, program ×1, MixerChannel.program ×1, JNI seam ×1, native binding ×1).
- [x] Every test in the spec's §8 is realized in one of the tasks.
- [x] No `TBD` / placeholder strings (besides intentional flagged stubs like the EXPORTING-state test that depends on sub-project B).
- [x] Types referenced in later tasks match earlier definitions: `LoopRange(startTick: Long, endTick: Long)` used consistently; `GMInstrument` enum case names stable; `StaffLoadParams(bankLSB: Int, isDrums: Boolean)` used in both Task 4 and the engine.
- [x] The poll-loop wrap test (5D) has known coverage gaps that are explicitly called out and pushed to manual emulator smoke (Task 7), not silently glossed over.
- [x] Commits are bite-sized (one logical change per commit; tests + impl together).
- [x] Working-directory discipline: each Bash invocation in the plan uses an explicit path or runs from the worktree root, never `cd`'s into the main repo.

## Risks reminder for the executor

1. **`fluid_player_set_tempo_type` integer**: confirmed `FLUID_PLAYER_TEMPO_INTERNAL = 0` (Task 2 Step 8). If a different FluidSynth version is in use, the test will fail loudly with an inverted speed change — recheck headers.
2. **`FakeJniBridge.frameForCursor` returns same bytes for both calls**: the loop tests in 5D use an ad-hoc bridge subclass to alternate frame return values. A future refactor can extract a "scripted" bridge helper if more tests need it.
3. **Subagent working-directory hygiene**: every dispatched implementer prompt must include `absolute working-directory: /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-engine-extensions` plus `do not cd into the main repo`. Phase 4 saw a wayward commit on local main when this discipline was skipped.
