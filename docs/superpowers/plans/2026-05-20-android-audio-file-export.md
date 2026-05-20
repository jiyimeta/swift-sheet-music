# Android audio file export — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Apple parity audio file export (WAV / AIFF / M4A / MP3) to Android via `AndroidPlaybackEngine.exportAudioFile(...)`, sharing tick-range resolution with the Apple path through `SheetMusicAudioCore`.

**Architecture:** A dedicated FluidSynth + PlayerDriver is built per export call (parity with Apple's fresh `AVAudioEngine`). The render loop pumps PCM via `fluid_synth_write_float` into one of four Kotlin encoders (RIFF/AIFF pure Kotlin, MediaCodec for AAC/MP3). Output target is `ParcelFileDescriptor` to be SAF-compatible. The Apple `resolveRange` / `resolveCursorTick` helpers move to `SheetMusicAudioCore/Export/AudioExportRange+Resolve.swift` and Android reaches them via a new `nativeResolveExportTickRange` JNI seam.

**Tech Stack:** Swift 6.3 (cross-compiled to Android via Swift Android SDK), Kotlin 2.0, Android API 28+, FluidSynth (VolcanoMobile prebuilt), MediaCodec, MediaMuxer, Compose, Swift Testing, JUnit 5.

**Reference spec:** [`docs/superpowers/specs/2026-05-20-android-audio-file-export-design.md`](../specs/2026-05-20-android-audio-file-export-design.md)

**Worktree:** `worktree-android-audio-export` at `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-audio-export`. All commands below assume this is the working directory.

---

## Task 0: Spike — verify FluidSynth offline render time model

**Files:**
- Modify (temporary spike, reverted at end of task): `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/synth/FluidSynthEngine.kt`

**Purpose:** Confirm that `fluid_synth_write_float` advances the player's scheduler by exactly N frames per call, independent of wall-clock, when Oboe is not pulling. The whole offline render design depends on this.

- [ ] **Step 1: Write a one-off spike test**

Create `Android/SheetMusicAudioAndroid/src/androidTest/kotlin/io/github/jiyimeta/sheetmusic/audio/spike/OfflineRenderSpikeTest.kt`:

```kotlin
package io.github.jiyimeta.sheetmusic.audio.spike

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.synth.FluidSynthDriver
import io.github.jiyimeta.sheetmusic.audio.synth.PlayerDriver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OfflineRenderSpikeTest {
    @Test fun fluidSynthWriteFloatAdvancesPlayerByFrameCount() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val resolver = SoundfontResolver.fromAssets(ctx)
        val sf2Uri = resolver.defaultGmSoundfontUri ?: error("install gm.sf2 first")

        val sampleRate = 48000
        val synth = FluidSynthDriver.create(sampleRate)
        val sfid = synth.loadSoundFont(sf2Uri, ctx)
        assertTrue("sfload should succeed", sfid >= 0)

        val player = PlayerDriver(synth.nativeHandle)
        // Trivial 4-bar 4/4 SMF stub asset would go here; for spike, reuse
        // the test fixture from Examples/Android (developer must run
        // Scripts/android-bundle-test-score.sh first).
        val smfBytes = ctx.assets.open("test.mid").readBytes()
        assertEquals(0, player.load(smfBytes))
        assertEquals(0, player.play())

        val startTick = player.currentTick
        val frames = 48000  // 1 second
        val left = FloatArray(frames)
        val right = FloatArray(frames)
        synth.writeFloat(frames, left, right)
        val endTick = player.currentTick

        // 1 second of audio should advance the tick by ≈ ticksPerBeat * BPM / 60.
        // For SMF at 480 PPQ + 120 BPM that's 960 ticks. Allow ±10% slack.
        assertTrue("player should have advanced", endTick > startTick)
        // Calling writeFloat a second time should advance by another ~same amount,
        // proving the advance is sample-pull driven, not wall-clock.
        synth.writeFloat(frames, left, right)
        val endTick2 = player.currentTick
        val delta1 = endTick - startTick
        val delta2 = endTick2 - endTick
        val ratio = delta1.toDouble() / delta2.toDouble()
        assertTrue("delta should be repeatable", ratio in 0.9..1.1)

        player.close(); synth.close()
    }
}
```

- [ ] **Step 2: Stage a known SMF as a test asset**

The spike needs a deterministic SMF. Generate one from a simple `.mscx`:

```bash
# From the worktree directory
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-audio-export

# Use the package's MidiRenderer to write a tiny SMF, save to assets.
swift run --package-path . sheet-music-cli render \
    Tests/SheetMusicTests/Resources/test01.mscx > /tmp/test.mid \
    2>/dev/null || true
# If sheet-music-cli doesn't exist, hand-craft a 4-bar 4/4 test.mid using
# any MIDI authoring tool and copy it manually.
mkdir -p Android/SheetMusicAudioAndroid/src/androidTest/assets
cp /tmp/test.mid Android/SheetMusicAudioAndroid/src/androidTest/assets/test.mid
```

- [ ] **Step 3: Run the spike**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:connectedDebugAndroidTest \
    --tests io.github.jiyimeta.sheetmusic.audio.spike.OfflineRenderSpikeTest
```

Expected: test passes. Both deltas are within 10% of each other, proving the player advances by samples pulled, not by wall-clock.

- [ ] **Step 4: Decide based on spike result**

If PASSED: proceed with the rest of the plan. Delete `OfflineRenderSpikeTest.kt` and the test SMF asset (the assumption is now documented).

If FAILED: STOP and report. Two pivot options exist per spec:
1. Attach a silent Oboe stream during export so the player runs against a real pull
2. Switch WAV/AIFF to FluidSynth's `fluid_file_renderer` (requires libsndfile in VolcanoMobile build — verify first), keep MediaCodec path for M4A/MP3

This is a strategy decision — surface to the user, do NOT pick unilaterally. See memory [[subagent-no-unilateral-pivot]].

- [ ] **Step 5: Commit (only if spike PASSED and was deleted)**

```bash
git add -u Android/SheetMusicAudioAndroid/src/androidTest/
git commit -m "spike: confirm FluidSynth offline render advances by frame pull"
```

Note: if the spike passed, no source files should be committed (the test and asset are deleted). The commit is empty in that case — skip it. Just leave a note in the next commit's message that the spike was run and passed.

---

## Task 1: Move `resolveRange` / `resolveCursorTick` to `SheetMusicAudioCore`

**Files:**
- Create: `Sources/SheetMusicAudioCore/Export/AudioExportRange+Resolve.swift`
- Create: `Tests/SheetMusicTests/AudioExportRangeResolveTests.swift`
- Modify: `Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift` (delete `resolveRange` / `resolveCursorTick`, call new method)

- [ ] **Step 1: Write failing tests**

Create `Tests/SheetMusicTests/AudioExportRangeResolveTests.swift`:

```swift
import Testing
@testable import SheetMusicAudioCore
@testable import SheetMusicCore

@Suite("AudioExportRange.resolveTickRange")
struct AudioExportRangeResolveTests {
    /// Build a minimal timeline covering 0..960 ticks across 2 measures at 480 PPQ.
    private func makeTimeline() -> PlaybackTimeline {
        // Reuse Tests/SheetMusicTests/Helpers/PlaybackTimelineFixture.swift if it
        // exists; otherwise construct inline. The fixture should have:
        // - division = 480
        // - 2 measures of 4/4 starting at tick 0 and 1920
        // - a Note item at tick 0 of measure 0 with itemEndTick = 480
        // - a Note item at tick 0 of measure 1 with itemEndTick = 2400
        // - measureStartTicks = [0, 1920]
        // Use the helper from Tests/SheetMusicTests/Helpers/ if it already
        // builds a deterministic timeline; otherwise add one in this file
        // scoped to this test file only.
        fatalError("build deterministic timeline; reuse existing helper if present")
    }

    @Test("full resolves to [0, totalTicks)")
    func resolveFull() throws {
        let tl = makeTimeline()
        let (s, e) = try AudioExportRange.full.resolveTickRange(timeline: tl, loop: nil)
        #expect(s == 0)
        #expect(e == tl.totalTicks)
    }

    @Test("currentLoop with loop set uses loop bounds")
    func resolveCurrentLoopWithLoop() throws {
        let tl = makeTimeline()
        let loop = LoopRange(startTick: 480, endTick: 1440)
        let (s, e) = try AudioExportRange.currentLoop.resolveTickRange(timeline: tl, loop: loop)
        #expect(s == 480)
        #expect(e == 1440)
    }

    @Test("currentLoop without loop falls back to full")
    func resolveCurrentLoopWithoutLoop() throws {
        let tl = makeTimeline()
        let (s, e) = try AudioExportRange.currentLoop.resolveTickRange(timeline: tl, loop: nil)
        #expect(s == 0)
        #expect(e == tl.totalTicks)
    }

    @Test("region with valid cursors returns their ticks")
    func resolveRegionHappy() throws {
        let tl = makeTimeline()
        let from = ScoreCursor.beat(measureIndex: 0, tickInMeasure: 0)
        let to = ScoreCursor.beat(measureIndex: 1, tickInMeasure: 0)
        let (s, e) = try AudioExportRange.region(from: from, to: to)
            .resolveTickRange(timeline: tl, loop: nil)
        #expect(s == 0)
        #expect(e == 1920)
    }

    @Test("region with unknown cursor throws rangeNotInTimeline")
    func resolveRegionInvalid() {
        let tl = makeTimeline()
        let from = ScoreCursor.beat(measureIndex: 99, tickInMeasure: 0)
        let to = ScoreCursor.beat(measureIndex: 1, tickInMeasure: 0)
        #expect(throws: AudioExportError.rangeNotInTimeline) {
            try AudioExportRange.region(from: from, to: to)
                .resolveTickRange(timeline: tl, loop: nil)
        }
    }

    @Test("regionThroughEnd uses itemEndTicks")
    func resolveRegionThroughEnd() throws {
        let tl = makeTimeline()
        let from = ScoreCursor.beat(measureIndex: 0, tickInMeasure: 0)
        // 'last' must be the ScoreItemID of the note in measure 1 — use
        // whatever ID the fixture uses.
        let last: ScoreItemID = .note(/* fixture-specific */ fatalError())
        let (s, e) = try AudioExportRange.regionThroughEnd(from: from, last: last)
            .resolveTickRange(timeline: tl, loop: nil)
        #expect(s == 0)
        #expect(e == 2400)
    }

    @Test(".beat cursor falls back when beat frame was deduped by item at same tick")
    func resolveBeatFallback() throws {
        // The .beat cursor at measure 0 / tick 0 should resolve even when the
        // note at tick 0 dedup'd the dedicated beat frame.
        let tl = makeTimeline()
        let cursor = ScoreCursor.beat(measureIndex: 0, tickInMeasure: 0)
        let (s, _) = try AudioExportRange.region(
            from: cursor,
            to: ScoreCursor.beat(measureIndex: 1, tickInMeasure: 0),
        ).resolveTickRange(timeline: tl, loop: nil)
        #expect(s == 0)
    }
}
```

The `makeTimeline()` helper needs a real fixture. Check `Tests/SheetMusicTests/Helpers/` for an existing `PlaybackTimelineFixture` or similar before writing inline. If you write inline, put the fixture in a separate file `Tests/SheetMusicTests/Helpers/PlaybackTimelineFixture.swift` for reuse.

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter AudioExportRangeResolveTests
```

Expected: compile error — `resolveTickRange` doesn't exist on `AudioExportRange`.

- [ ] **Step 3: Implement the extension**

Create `Sources/SheetMusicAudioCore/Export/AudioExportRange+Resolve.swift`. Copy the logic from `Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift`'s private static `resolveRange(_:timeline:loop:)` and `resolveCursorTick(_:in:)`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicMIDI

extension AudioExportRange {
    /// Resolve to a half-open `[startTick, endTick)` tick range against
    /// the score's `PlaybackTimeline`, with optional `loop` for `.currentLoop`.
    public func resolveTickRange(
        timeline: PlaybackTimeline,
        loop: LoopRange?,
    ) throws -> (startTick: Int, endTick: Int) {
        switch self {
        case .full:
            return (0, timeline.totalTicks)
        case .currentLoop:
            if let loop {
                return (loop.startTick, loop.endTick)
            }
            return (0, timeline.totalTicks)
        case let .region(from, to):
            guard let sTick = Self.resolveCursorTick(from, in: timeline),
                  let eTick = Self.resolveCursorTick(to, in: timeline),
                  sTick < eTick
            else { throw AudioExportError.rangeNotInTimeline }
            return (sTick, eTick)
        case let .regionThroughEnd(from, last):
            guard let sTick = Self.resolveCursorTick(from, in: timeline),
                  let endTick = timeline.itemEndTicks[last],
                  sTick < endTick
            else { throw AudioExportError.rangeNotInTimeline }
            return (sTick, endTick)
        }
    }

    /// Resolve a `ScoreCursor` to a timeline tick, with fallback for `.beat`
    /// cursors whose tick is occupied by a chord/rest frame (and therefore
    /// has no dedicated `.beat` frame).
    static func resolveCursorTick(
        _ cursor: ScoreCursor,
        in timeline: PlaybackTimeline,
    ) -> Int? {
        if let frame = timeline.frame(forCursor: cursor) {
            return frame.tick
        }
        guard case let .beat(measureIndex: mi, tickInMeasure: tim) = cursor else {
            return nil
        }
        for frame in timeline.frames {
            if case let .beat(measureIndex: fmi, tickInMeasure: ftim) = frame.cursor,
               fmi == mi
            {
                let measureStart = frame.tick - ftim
                let absoluteTick = measureStart + tim
                if absoluteTick >= 0, absoluteTick <= timeline.totalTicks {
                    return absoluteTick
                }
            }
        }
        var measureStartTick: Int?
        for (id, tick) in timeline.itemTicks {
            guard id.measureIndex == mi else { continue }
            if let existing = measureStartTick {
                measureStartTick = min(existing, tick)
            } else {
                measureStartTick = tick
            }
        }
        if let start = measureStartTick {
            let absoluteTick = start + tim
            if absoluteTick >= 0, absoluteTick <= timeline.totalTicks {
                return absoluteTick
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Update Apple call site**

In `Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift`:

1. Delete the private `static func resolveRange(_:timeline:loop:)` and `static func resolveCursorTick(_:in:)`.
2. Change the call in `exportAudioFile(...)`:

Before:
```swift
let (startTick, endTick) = try Self.resolveRange(
    range, timeline: timeline, loop: loopRange,
)
```

After:
```swift
let (startTick, endTick) = try range.resolveTickRange(
    timeline: timeline, loop: loopRange,
)
```

- [ ] **Step 5: Run tests**

```bash
swift test --filter AudioExportRangeResolveTests
swift test --filter AudioFileExportTests  # existing Apple tests should still pass
```

Expected: both PASS.

- [ ] **Step 6: Android cross-compile sanity**

```bash
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
    swift build --swift-sdk aarch64-unknown-linux-android28
```

Expected: succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicAudioCore/Export/AudioExportRange+Resolve.swift \
        Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift \
        Tests/SheetMusicTests/AudioExportRangeResolveTests.swift \
        Tests/SheetMusicTests/Helpers/PlaybackTimelineFixture.swift
git commit -m "refactor(audio): lift AudioExportRange tick resolution to Core"
```

---

## Task 2: Kotlin AudioFileFormat / PCMOptions / CompressedOptions

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/model/AudioFileFormat.kt`
- Create: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/model/AudioFileFormatTest.kt`

- [ ] **Step 1: Write failing tests**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.model

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class AudioFileFormatTest {
    @Test fun pcmOptionsDefaultIsStereoInt16At44100() {
        val opts = PcmOptions()
        assertEquals(44100, opts.sampleRate)
        assertEquals(PcmBitDepth.Int16, opts.bitDepth)
        assertEquals(AudioChannelCount.Stereo, opts.channels)
    }

    @Test fun compressedOptionsDefaultIs192kbps() {
        val opts = CompressedOptions()
        assertEquals(44100, opts.sampleRate)
        assertEquals(192_000, opts.bitRate)
        assertEquals(AudioChannelCount.Stereo, opts.channels)
    }

    @Test fun audioFileFormatVariantsCarryTheirOptions() {
        val pcm = PcmOptions(sampleRate = 48000, bitDepth = PcmBitDepth.Float32, channels = AudioChannelCount.Mono)
        val wav = AudioFileFormat.Wav(pcm)
        assertEquals(48000, wav.options.sampleRate)
        val compressed = CompressedOptions(sampleRate = 22050, bitRate = 96_000, channels = AudioChannelCount.Mono)
        val mp3 = AudioFileFormat.Mp3(compressed)
        assertEquals(96_000, mp3.options.bitRate)
    }

    @Test fun audioChannelCountRawValueMatchesChannelCount() {
        assertEquals(1, AudioChannelCount.Mono.rawValue)
        assertEquals(2, AudioChannelCount.Stereo.rawValue)
    }
}
```

- [ ] **Step 2: Verify test fails**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AudioFileFormatTest"
```

Expected: compile error — types don't exist.

- [ ] **Step 3: Implement**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.model

enum class PcmBitDepth { Int16, Int24, Int32, Float32 }

enum class AudioChannelCount(val rawValue: Int) {
    Mono(1), Stereo(2)
}

data class PcmOptions(
    val sampleRate: Int = 44100,
    val bitDepth: PcmBitDepth = PcmBitDepth.Int16,
    val channels: AudioChannelCount = AudioChannelCount.Stereo,
)

data class CompressedOptions(
    val sampleRate: Int = 44100,
    val bitRate: Int = 192_000,
    val channels: AudioChannelCount = AudioChannelCount.Stereo,
)

sealed interface AudioFileFormat {
    data class Wav(val options: PcmOptions = PcmOptions()) : AudioFileFormat
    data class Aiff(val options: PcmOptions = PcmOptions()) : AudioFileFormat
    data class M4a(val options: CompressedOptions = CompressedOptions()) : AudioFileFormat
    data class Mp3(val options: CompressedOptions = CompressedOptions()) : AudioFileFormat
}
```

- [ ] **Step 4: Run test**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AudioFileFormatTest"
```

Expected: 4/4 PASS.

- [ ] **Step 5: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/model/AudioFileFormat.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/model/AudioFileFormatTest.kt
git commit -m "feat(android-audio): Kotlin AudioFileFormat + options types"
```

---

## Task 3: Kotlin AudioExportRange + serialization encoder

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/model/AudioExportRange.kt`
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/AudioExportRangeEncoder.kt`
- Create: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/AudioExportRangeEncoderTest.kt`

- [ ] **Step 1: Write failing test**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.AudioExportRange
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class AudioExportRangeEncoderTest {
    @Test fun encodesFullAsTagZeroOnly() {
        val bytes = AudioExportRangeEncoder.encode(AudioExportRange.Full)
        // Header: u16=1 (version) + u8=0 (Full tag) = 3 bytes
        assertArrayEquals(byteArrayOf(0x01, 0x00, 0x00), bytes)
    }

    @Test fun encodesCurrentLoopAsTagOneOnly() {
        val bytes = AudioExportRangeEncoder.encode(AudioExportRange.CurrentLoop)
        assertArrayEquals(byteArrayOf(0x01, 0x00, 0x01), bytes)
    }

    @Test fun encodesRegionWithCursorPair() {
        val from = ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val to = ScoreCursor.Beat(measureIndex = 1, tickInMeasure = 240)
        val bytes = AudioExportRangeEncoder.encode(AudioExportRange.Region(from, to))
        // Header (3 bytes: u16 version + u8 tag) + two ScoreCursor payloads.
        // Verify total length and that decoding the cursor payloads yields the
        // original — match ScoreCursorCodec.encodePayload's byte width:
        // tag(1) + measureIndex(4) + tickInMeasure(4) = 9 bytes per cursor.
        assertEquals(3 + 9 + 9, bytes.size)
        assertEquals(0x02.toByte(), bytes[2])  // Region tag
    }

    @Test fun encodesRegionThroughEndWithCursorAndItemID() {
        val from = ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val last = ScoreItemID.Note(NoteID(
            staff = StaffAddress(0, 0),
            measureIndex = 1, voiceIndex = 0,
            elementIndex = 3, noteIndexInChord = 0,
        ))
        val bytes = AudioExportRangeEncoder.encode(AudioExportRange.RegionThroughEnd(from, last))
        // Header (3) + cursor (9) + ScoreItemID (tag 1 + Note payload 4*5 = 21)
        assertEquals(3 + 9 + 21, bytes.size)
        assertEquals(0x03.toByte(), bytes[2])
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AudioExportRangeEncoderTest"
```

Expected: compile error — `AudioExportRange` doesn't exist.

- [ ] **Step 3: Implement the model + encoder**

`model/AudioExportRange.kt`:

```kotlin
package io.github.jiyimeta.sheetmusic.audio.model

sealed interface AudioExportRange {
    object Full : AudioExportRange
    object CurrentLoop : AudioExportRange
    data class Region(val from: ScoreCursor, val to: ScoreCursor) : AudioExportRange
    data class RegionThroughEnd(val from: ScoreCursor, val last: ScoreItemID) : AudioExportRange
}
```

`serialization/AudioExportRangeEncoder.kt`:

```kotlin
package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.AudioExportRange

internal object AudioExportRangeEncoder {
    fun encode(range: AudioExportRange): ByteArray {
        val w = BinaryWriter()
        w.writeU16(1)  // version
        when (range) {
            is AudioExportRange.Full -> w.writeU8(0)
            is AudioExportRange.CurrentLoop -> w.writeU8(1)
            is AudioExportRange.Region -> {
                w.writeU8(2)
                ScoreCursorCodec.encodePayload(range.from, w)
                ScoreCursorCodec.encodePayload(range.to, w)
            }
            is AudioExportRange.RegionThroughEnd -> {
                w.writeU8(3)
                ScoreCursorCodec.encodePayload(range.from, w)
                ScoreItemIDCodec.encodePayload(range.last, w)
            }
        }
        return w.toByteArray()
    }
}
```

- [ ] **Step 4: Run test**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AudioExportRangeEncoderTest"
```

Expected: 4/4 PASS. If the size assertions fail, inspect the actual `BinaryWriter` LE format and `ScoreCursorCodec.encodePayload` byte layout — adjust the assertions to match the real layout (the test exists to detect future regressions, not to enforce a fictional layout).

- [ ] **Step 5: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/model/AudioExportRange.kt \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/AudioExportRangeEncoder.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/AudioExportRangeEncoderTest.kt
git commit -m "feat(android-audio): AudioExportRange model + wire-format encoder"
```

---

## Task 4: Swift JNI seam — `nativeResolveExportTickRange`

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Audio/AudioExportRangeJNICodec.swift`
- Create: `Sources/SheetMusicAndroidJNI/Audio/AudioExportRangeJNI.swift`
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt`
- Create: `Tests/SheetMusicAndroidJNITests/AudioExportRangeJNICodecTests.swift`

The Swift Android tests folder name should match the existing pattern — check `Tests/` for a `SheetMusicAndroidJNI`-flavored test target first; if there isn't one, add the new test to `Tests/SheetMusicTests/` and rely on the cross-platform Foundation-only build.

- [ ] **Step 1: Write failing decoder test**

```swift
import Testing
@testable import SheetMusicAndroidJNI
@testable import SheetMusicCore

@Suite("AudioExportRangeJNICodec")
struct AudioExportRangeJNICodecTests {
    @Test("decode Full")
    func decodeFull() throws {
        let bytes: [UInt8] = [0x01, 0x00, 0x00]
        let range = try AudioExportRangeJNICodec.decode(Data(bytes))
        if case .full = range { /* ok */ } else { Issue.record("expected .full") }
    }

    @Test("decode CurrentLoop")
    func decodeCurrentLoop() throws {
        let bytes: [UInt8] = [0x01, 0x00, 0x01]
        let range = try AudioExportRangeJNICodec.decode(Data(bytes))
        if case .currentLoop = range { /* ok */ } else { Issue.record("expected .currentLoop") }
    }

    @Test("decode Region cursor pair")
    func decodeRegion() throws {
        // 3-byte header + two beat cursors (tag 1 + measureIndex u32 + tickInMeasure u32 = 9 each)
        var bytes: [UInt8] = [0x01, 0x00, 0x02]
        // from = .beat(measureIndex: 0, tickInMeasure: 0)
        bytes += [0x01]  // ScoreCursor.beat tag
        bytes += [0,0,0,0]  // measureIndex 0 LE
        bytes += [0,0,0,0]  // tickInMeasure 0 LE
        // to = .beat(measureIndex: 1, tickInMeasure: 240)
        bytes += [0x01]
        bytes += [1,0,0,0]
        bytes += [240,0,0,0]
        let range = try AudioExportRangeJNICodec.decode(Data(bytes))
        guard case let .region(from, to) = range else {
            Issue.record("expected .region"); return
        }
        guard case let .beat(fmi, ftim) = from else { Issue.record("from beat"); return }
        #expect(fmi == 0); #expect(ftim == 0)
        guard case let .beat(tmi, ttim) = to else { Issue.record("to beat"); return }
        #expect(tmi == 1); #expect(ttim == 240)
    }
}
```

- [ ] **Step 2: Run + verify fail**

```bash
swift test --filter AudioExportRangeJNICodecTests
```

Expected: compile error — type doesn't exist.

- [ ] **Step 3: Implement the codec**

`Sources/SheetMusicAndroidJNI/Audio/AudioExportRangeJNICodec.swift`:

```swift
import Foundation
import SheetMusicAudioCore
import SheetMusicCore

/// Decodes the wire format written by the Kotlin
/// `AudioExportRangeEncoder.encode(_:)` (3-byte header + tag + payload).
enum AudioExportRangeJNICodec {
    static func decode(_ data: Data) throws -> AudioExportRange {
        var reader = BinaryReader(data: data)
        let version = try reader.readU16()
        guard version == 1 else { throw DecodeError.unsupportedVersion(version) }
        let tag = try reader.readU8()
        switch tag {
        case 0: return .full
        case 1: return .currentLoop
        case 2:
            let from = try ScoreCursorJNICodec.decodePayload(&reader)
            let to = try ScoreCursorJNICodec.decodePayload(&reader)
            return .region(from: from, to: to)
        case 3:
            let from = try ScoreCursorJNICodec.decodePayload(&reader)
            let last = try ScoreItemIDJNICodec.decodePayload(&reader)
            return .regionThroughEnd(from: from, last: last)
        default:
            throw DecodeError.unknownTag(tag)
        }
    }

    enum DecodeError: Error, Equatable {
        case unsupportedVersion(UInt16)
        case unknownTag(UInt8)
    }
}
```

If `ScoreCursorJNICodec` / `ScoreItemIDJNICodec` don't exist yet on the Swift side, check `Sources/SheetMusicAndroidJNI/` for the existing CursorBridge / ScoreItemID decoders. Reuse those entry points; do not duplicate. If only encoders exist (Swift → bytes for outbound), add `decodePayload(_:)` mirror functions in a new sibling file `Audio/ScoreCursorJNICodec.swift`.

- [ ] **Step 4: Run tests**

```bash
swift test --filter AudioExportRangeJNICodecTests
```

Expected: 3/3 PASS.

- [ ] **Step 5: Write the `@_cdecl` JNI symbol**

`Sources/SheetMusicAndroidJNI/Audio/AudioExportRangeJNI.swift`:

```swift
#if os(Android)
    import CJNI
    import Foundation
    import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicMIDI

    @_cdecl("Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeResolveExportTickRange")
    public func Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeResolveExportTickRange(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ rangeBytes: jbyteArray,
    ) -> jlongArray? {
        guard let env = envPtr.pointee,
              let score = scoreTable.get(scoreHandle) else {
            return makeResultArray(envPtr: envPtr, start: -1, end: -1)
        }
        let len = env.pointee.GetArrayLength(envPtr, rangeBytes)
        guard len > 0 else {
            return makeResultArray(envPtr: envPtr, start: -1, end: -1)
        }
        var bytes = [UInt8](repeating: 0, count: Int(len))
        bytes.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            base.withMemoryRebound(to: jbyte.self, capacity: Int(len)) { jbytes in
                env.pointee.GetByteArrayRegion(envPtr, rangeBytes, 0, len, jbytes)
            }
        }
        do {
            let range = try AudioExportRangeJNICodec.decode(Data(bytes))
            let timeline = try PlaybackTimeline.build(for: score)
            let (start, end) = try range.resolveTickRange(timeline: timeline, loop: nil)
            return makeResultArray(envPtr: envPtr, start: Int64(start), end: Int64(end))
        } catch {
            return makeResultArray(envPtr: envPtr, start: -1, end: -1)
        }
    }

    private func makeResultArray(
        envPtr: UnsafeMutablePointer<JNIEnv?>, start: Int64, end: Int64,
    ) -> jlongArray? {
        guard let env = envPtr.pointee else { return nil }
        let array = env.pointee.NewLongArray(envPtr, 2)
        var values: [jlong] = [jlong(start), jlong(end)]
        values.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            env.pointee.SetLongArrayRegion(envPtr, array, 0, 2, base)
        }
        return array
    }
#endif
```

If `PlaybackTimeline.build(for:)` is not the exact existing entry point, search `Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift` for whichever helper is used today for `nativeTimelineSummary` and reuse it (or call its underlying builder).

The `loop: nil` arg is intentional: the Apple `.currentLoop` case is engine-state-dependent. On Android, the engine's `loopRange` lives in Kotlin and is passed separately if needed. For now, `.currentLoop` falls back to `.full` on the JNI seam. The Kotlin caller's `AndroidPlaybackEngine.exportAudioFile` is responsible for substituting `.currentLoop` with an explicit `.region` constructed from `_loopRange.value` before calling JNI (or for accepting the `.full` fallback semantics).

- [ ] **Step 6: Add Kotlin external fun**

Edit `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt` — add:

```kotlin
external fun nativeResolveExportTickRange(
    scoreHandle: Long,
    rangeBytes: ByteArray,
): LongArray
```

- [ ] **Step 7: Cross-compile + library tests**

```bash
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
    swift build --swift-sdk aarch64-unknown-linux-android28
swift test --filter AudioExportRangeJNICodecTests
```

Expected: both succeed.

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/Audio/AudioExportRangeJNICodec.swift \
        Sources/SheetMusicAndroidJNI/Audio/AudioExportRangeJNI.swift \
        Sources/SheetMusicAndroidJNI/Audio/ScoreCursorJNICodec.swift \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt \
        Tests/SheetMusicTests/AudioExportRangeJNICodecTests.swift
git commit -m "feat(android-jni): nativeResolveExportTickRange seam"
```

---

## Task 5: AudioBackendException additions

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AudioBackendException.kt`
- Modify: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AudioBackendExceptionTest.kt`

- [ ] **Step 1: Add failing assertions to the existing test**

Open the existing `AudioBackendExceptionTest.kt`. Add tests for the five new subclasses:

```kotlin
@Test fun noScorePreparedHasReadableMessage() {
    val e = AudioBackendException.NoScorePrepared()
    assertTrue(e.message!!.contains("No score prepared"))
}

@Test fun rangeNotInTimelineHasReadableMessage() {
    val e = AudioBackendException.RangeNotInTimeline()
    assertTrue(e.message!!.contains("not in timeline"))
}

@Test fun formatUnsupportedCarriesFormat() {
    val fmt = AudioFileFormat.Mp3()
    val e = AudioBackendException.FormatUnsupportedOnThisOS(fmt)
    assertEquals(fmt, e.format)
}

@Test fun fileWriteFailedHasCause() {
    val cause = RuntimeException("disk full")
    val e = AudioBackendException.FileWriteFailed(cause)
    assertSame(cause, e.cause)
}

@Test fun cancelledIsKotlinException() {
    val e = AudioBackendException.Cancelled()
    assertTrue(e.message!!.contains("cancelled"))
}
```

- [ ] **Step 2: Verify fail**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AudioBackendExceptionTest"
```

Expected: compile error — new subclasses don't exist.

- [ ] **Step 3: Add the subclasses**

In `AudioBackendException.kt`, inside the sealed class:

```kotlin
class NoScorePrepared :
    AudioBackendException("No score prepared for export")
class RangeNotInTimeline :
    AudioBackendException("Export range is not in timeline")
class FormatUnsupportedOnThisOS(val format: AudioFileFormat) :
    AudioBackendException("Format unsupported on this OS: $format")
class FileWriteFailed(cause: Throwable?) :
    AudioBackendException("File write failed: ${cause?.message ?: "unknown"}") {
    init { initCause(cause) }
}
class Cancelled :
    AudioBackendException("Export was cancelled")
```

Don't forget to `import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat`.

- [ ] **Step 4: Run test**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AudioBackendExceptionTest"
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AudioBackendException.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AudioBackendExceptionTest.kt
git commit -m "feat(android-audio): export-related AudioBackendException subclasses"
```

---

## Task 6: Shared float→int conversion helpers

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/PcmSampleConversion.kt`
- Create: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/PcmSampleConversionTest.kt`

These helpers are used by WAV / AIFF / M4A / MP3 encoders. Implementing them up front avoids duplication.

- [ ] **Step 1: Write failing tests**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class PcmSampleConversionTest {
    @Test fun floatToInt16InterleavesStereo() {
        val left = floatArrayOf(0f, 0.5f, -0.5f)
        val right = floatArrayOf(0f, -0.5f, 0.5f)
        val out = ShortArray(6)
        PcmSampleConversion.floatToInt16Interleaved(left, right, frames = 3, mono = false, out = out)
        assertEquals(0, out[0].toInt())
        assertEquals(0, out[1].toInt())
        assertEquals(16383, out[2].toInt())  // 0.5 * 32767 ≈ 16383
        assertEquals(-16383, out[3].toInt())
        assertEquals(-16383, out[4].toInt())
        assertEquals(16383, out[5].toInt())
    }

    @Test fun floatToInt16ClipsAtBoundaries() {
        val left = floatArrayOf(2.0f, -2.0f)
        val right = floatArrayOf(2.0f, -2.0f)
        val out = ShortArray(4)
        PcmSampleConversion.floatToInt16Interleaved(left, right, frames = 2, mono = false, out = out)
        assertEquals(32767, out[0].toInt())
        assertEquals(-32768, out[1].toInt())
        assertEquals(32767, out[2].toInt())
        assertEquals(-32768, out[3].toInt())
    }

    @Test fun floatToInt16MonoDropsRightChannel() {
        val left = floatArrayOf(0.5f, -0.5f)
        val right = floatArrayOf(0.25f, -0.25f)  // ignored
        val out = ShortArray(2)
        PcmSampleConversion.floatToInt16Interleaved(left, right, frames = 2, mono = true, out = out)
        assertEquals(16383, out[0].toInt())
        assertEquals(-16383, out[1].toInt())
    }

    @Test fun floatToInt24EncodesLittleEndian() {
        val left = floatArrayOf(0.5f)
        val right = floatArrayOf(0f)
        val out = ByteArray(6)  // 3 bytes per sample, stereo
        PcmSampleConversion.floatToInt24LE(left, right, frames = 1, mono = false, out = out)
        // 0.5 * 2^23 = 4194304 → 0x400000 → LE: 0x00 0x00 0x40
        assertEquals(0x00, out[0].toInt() and 0xFF)
        assertEquals(0x00, out[1].toInt() and 0xFF)
        assertEquals(0x40, out[2].toInt() and 0xFF)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.PcmSampleConversionTest"
```

Expected: compile error.

- [ ] **Step 3: Implement**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import java.nio.ByteBuffer
import java.nio.ByteOrder

internal object PcmSampleConversion {
    private const val INT16_MAX_F = 32767f
    private const val INT24_MAX_F = 8388607f
    private const val INT32_MAX_F = 2147483647f

    fun floatToInt16Interleaved(
        left: FloatArray, right: FloatArray, frames: Int, mono: Boolean, out: ShortArray,
    ) {
        if (mono) {
            for (i in 0 until frames) {
                out[i] = clipInt16(left[i])
            }
        } else {
            var j = 0
            for (i in 0 until frames) {
                out[j++] = clipInt16(left[i])
                out[j++] = clipInt16(right[i])
            }
        }
    }

    fun floatToInt24LE(
        left: FloatArray, right: FloatArray, frames: Int, mono: Boolean, out: ByteArray,
    ) {
        var p = 0
        for (i in 0 until frames) {
            p = writeInt24LE(left[i], out, p)
            if (!mono) p = writeInt24LE(right[i], out, p)
        }
    }

    fun floatToInt32LE(
        left: FloatArray, right: FloatArray, frames: Int, mono: Boolean, out: ByteArray,
    ) {
        val bb = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until frames) {
            bb.putInt(clipInt32(left[i]))
            if (!mono) bb.putInt(clipInt32(right[i]))
        }
    }

    fun floatToFloat32LE(
        left: FloatArray, right: FloatArray, frames: Int, mono: Boolean, out: ByteArray,
    ) {
        val bb = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until frames) {
            bb.putFloat(left[i])
            if (!mono) bb.putFloat(right[i])
        }
    }

    fun floatToFloat32BE(
        left: FloatArray, right: FloatArray, frames: Int, mono: Boolean, out: ByteArray,
    ) {
        val bb = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN)
        for (i in 0 until frames) {
            bb.putFloat(left[i])
            if (!mono) bb.putFloat(right[i])
        }
    }

    fun floatToInt16InterleavedBE(
        left: FloatArray, right: FloatArray, frames: Int, mono: Boolean, out: ByteArray,
    ) {
        val bb = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN)
        for (i in 0 until frames) {
            bb.putShort(clipInt16(left[i]))
            if (!mono) bb.putShort(clipInt16(right[i]))
        }
    }

    fun floatToInt24BE(
        left: FloatArray, right: FloatArray, frames: Int, mono: Boolean, out: ByteArray,
    ) {
        var p = 0
        for (i in 0 until frames) {
            p = writeInt24BE(left[i], out, p)
            if (!mono) p = writeInt24BE(right[i], out, p)
        }
    }

    fun floatToInt32BE(
        left: FloatArray, right: FloatArray, frames: Int, mono: Boolean, out: ByteArray,
    ) {
        val bb = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN)
        for (i in 0 until frames) {
            bb.putInt(clipInt32(left[i]))
            if (!mono) bb.putInt(clipInt32(right[i]))
        }
    }

    private fun clipInt16(x: Float): Short {
        val v = (x * INT16_MAX_F).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
        return v.toShort()
    }

    private fun clipInt32(x: Float): Int {
        val v = (x.toDouble() * INT32_MAX_F).toLong().coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong())
        return v.toInt()
    }

    private fun clipInt24(x: Float): Int {
        return (x * INT24_MAX_F).toInt().coerceIn(-8388608, 8388607)
    }

    private fun writeInt24LE(x: Float, out: ByteArray, offset: Int): Int {
        val v = clipInt24(x)
        out[offset] = (v and 0xFF).toByte()
        out[offset + 1] = ((v ushr 8) and 0xFF).toByte()
        out[offset + 2] = ((v ushr 16) and 0xFF).toByte()
        return offset + 3
    }

    private fun writeInt24BE(x: Float, out: ByteArray, offset: Int): Int {
        val v = clipInt24(x)
        out[offset] = ((v ushr 16) and 0xFF).toByte()
        out[offset + 1] = ((v ushr 8) and 0xFF).toByte()
        out[offset + 2] = (v and 0xFF).toByte()
        return offset + 3
    }
}
```

- [ ] **Step 4: Run test**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.PcmSampleConversionTest"
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/PcmSampleConversion.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/PcmSampleConversionTest.kt
git commit -m "feat(android-audio): float→int PCM sample conversion helpers"
```

---

## Task 7: AudioFileEncoder interface + factory

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioFileEncoder.kt`

- [ ] **Step 1: Write the interface (no tests — pure interface)**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat

internal interface AudioFileEncoder : AutoCloseable {
    /**
     * Append [frames] frames of stereo float32 audio to the encoder.
     * For mono encoders, only [left] is consumed.
     */
    fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int)

    /** Finalize headers / muxer. Must be called before [close] on the happy path. */
    fun finish()

    companion object {
        fun create(
            format: AudioFileFormat,
            sampleRate: Int,
            fd: ParcelFileDescriptor,
        ): AudioFileEncoder = when (format) {
            is AudioFileFormat.Wav -> WavPcmEncoder(format.options, sampleRate, fd.fileDescriptor)
            is AudioFileFormat.Aiff -> AiffPcmEncoder(format.options, sampleRate, fd.fileDescriptor)
            is AudioFileFormat.M4a -> AacM4aEncoder(format.options, sampleRate, fd)
            is AudioFileFormat.Mp3 -> Mp3MediaCodecEncoder(format.options, sampleRate, fd)
        }

        // WAV/AIFF take FileDescriptor directly so JVM unit tests can drive
        // them with RandomAccessFile.fd. M4A/MP3 need the full
        // ParcelFileDescriptor because MediaMuxer/MediaCodec consume it.
    }
}
```

- [ ] **Step 2: Build verification**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:compileDebugKotlin
```

Expected: compile error — encoder classes don't exist yet. That's fine; subsequent tasks will add them. Move on without committing.

The four encoder classes are added in tasks 8 / 9 / 10 / 11; only after all four are present does this file compile and get committed in Task 11.

---

## Task 8: WavPcmEncoder

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/WavPcmEncoder.kt`
- Create: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/WavPcmEncoderTest.kt`

- [ ] **Step 1: Write failing test**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.PcmBitDepth
import io.github.jiyimeta.sheetmusic.audio.model.PcmOptions
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

class WavPcmEncoderTest {
    @Test fun stereoInt16At44100ProducesValidWavHeader(@TempDir tmp: File) {
        val out = File(tmp, "test.wav")
        val opts = PcmOptions(sampleRate = 44100, bitDepth = PcmBitDepth.Int16, channels = AudioChannelCount.Stereo)
        val raf = RandomAccessFile(out, "rw")
        WavPcmEncoder(opts, 44100, raf.fd).use { enc ->
            enc.appendPcmFloat(floatArrayOf(0.5f), floatArrayOf(-0.5f), 1)
            enc.finish()
        }
        raf.close()
        // Verify RIFF/WAVE header
        val bytes = out.readBytes()
        assertEquals("RIFF", String(bytes, 0, 4))
        assertEquals("WAVE", String(bytes, 8, 4))
        assertEquals("fmt ", String(bytes, 12, 4))
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        bb.position(22); assertEquals(2, bb.short.toInt())  // channels
        bb.position(24); assertEquals(44100, bb.int)        // sample rate
        bb.position(34); assertEquals(16, bb.short.toInt()) // bits per sample
        // Data chunk size = 2 channels * 2 bytes * 1 frame = 4
        bb.position(40); assertEquals(4, bb.int)
        // First sample (LE int16): 0.5 → 16383
        assertEquals(16383, ByteBuffer.wrap(bytes, 44, 2)
            .order(ByteOrder.LITTLE_ENDIAN).short.toInt())
    }

    @Test fun monoFloat32EncodesFloatFormatTag(@TempDir tmp: File) {
        val out = File(tmp, "test.wav")
        val opts = PcmOptions(sampleRate = 48000, bitDepth = PcmBitDepth.Float32, channels = AudioChannelCount.Mono)
        val raf = RandomAccessFile(out, "rw")
        WavPcmEncoder(opts, 48000, raf.fd).use { enc ->
            enc.appendPcmFloat(floatArrayOf(1.0f, 0.5f), floatArrayOf(0f, 0f), 2)
            enc.finish()
        }
        raf.close()
        val bytes = out.readBytes()
        // fmt tag at offset 20 for float WAV is 3 (WAVE_FORMAT_IEEE_FLOAT)
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        bb.position(20); assertEquals(3, bb.short.toInt())
        bb.position(22); assertEquals(1, bb.short.toInt())  // mono
    }
}
```

Note: `ParcelFileDescriptor.open(File, ...)` requires the Android SDK; this test compiles under the `test/` source set's JVM target only if `androidx.test.core` provides shims. If pure JVM can't open a `ParcelFileDescriptor`, move this test to `androidTest/` and use Robolectric, or use a `java.io.FileDescriptor`-based seam in the encoder (constructor takes `FileDescriptor` not `ParcelFileDescriptor`; the outer wrapper extracts `fd.fileDescriptor`). The latter is simpler — refactor `WavPcmEncoder` to accept `FileDescriptor` and have the factory in Task 7 do the extraction. Test follows.

- [ ] **Step 2: Verify fail**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.WavPcmEncoderTest"
```

Expected: compile error.

- [ ] **Step 3: Implement**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.PcmBitDepth
import io.github.jiyimeta.sheetmusic.audio.model.PcmOptions
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal class WavPcmEncoder(
    private val options: PcmOptions,
    sampleRate: Int,
    fd: java.io.FileDescriptor,
) : AudioFileEncoder {
    private val raf = RandomAccessFile(fd, "rw")
    private val mono = options.channels == AudioChannelCount.Mono
    private val bytesPerSample: Int = when (options.bitDepth) {
        PcmBitDepth.Int16 -> 2
        PcmBitDepth.Int24 -> 3
        PcmBitDepth.Int32 -> 4
        PcmBitDepth.Float32 -> 4
    }
    private val frameBytes: Int = bytesPerSample * options.channels.rawValue
    private var dataBytesWritten: Int = 0
    private var finished = false

    init {
        writeHeader()
    }

    private fun writeHeader() {
        val isFloat = options.bitDepth == PcmBitDepth.Float32
        val fmtChunkSize = 16  // PCM and IEEE_FLOAT both fit 16-byte fmt chunk
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray())
        header.putInt(0)  // RIFF size, backfilled in finish()
        header.put("WAVE".toByteArray())
        header.put("fmt ".toByteArray())
        header.putInt(fmtChunkSize)
        header.putShort(if (isFloat) 3.toShort() else 1.toShort())  // format tag
        header.putShort(options.channels.rawValue.toShort())
        header.putInt(options.sampleRate)
        header.putInt(options.sampleRate * frameBytes)  // byteRate
        header.putShort(frameBytes.toShort())  // blockAlign
        header.putShort((bytesPerSample * 8).toShort())  // bits per sample
        header.put("data".toByteArray())
        header.putInt(0)  // data size, backfilled in finish()
        raf.write(header.array(), 0, 44)
    }

    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        val payload = ByteArray(frames * frameBytes)
        when (options.bitDepth) {
            PcmBitDepth.Int16 -> {
                val tmp = ShortArray(frames * options.channels.rawValue)
                PcmSampleConversion.floatToInt16Interleaved(left, right, frames, mono, tmp)
                val bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
                for (s in tmp) bb.putShort(s)
            }
            PcmBitDepth.Int24 -> PcmSampleConversion.floatToInt24LE(left, right, frames, mono, payload)
            PcmBitDepth.Int32 -> PcmSampleConversion.floatToInt32LE(left, right, frames, mono, payload)
            PcmBitDepth.Float32 -> PcmSampleConversion.floatToFloat32LE(left, right, frames, mono, payload)
        }
        raf.write(payload)
        dataBytesWritten += payload.size
    }

    override fun finish() {
        if (finished) return
        // RIFF size at offset 4 = total file size - 8
        val riffSize = 36 + dataBytesWritten
        raf.seek(4); raf.write(intToLEBytes(riffSize))
        // data size at offset 40
        raf.seek(40); raf.write(intToLEBytes(dataBytesWritten))
        raf.fd.sync()
        finished = true
    }

    override fun close() {
        try { if (!finished) raf.fd.sync() } catch (_: Throwable) {}
        raf.close()
    }

    private fun intToLEBytes(v: Int): ByteArray {
        val bb = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(v)
        return bb.array()
    }
}
```

- [ ] **Step 4: Run test**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.WavPcmEncoderTest"
```

Expected: 2/2 PASS.

JVM tests above use `java.io.RandomAccessFile.fd` directly because `ParcelFileDescriptor.open` is not available in pure JVM. The encoder constructor accepts `java.io.FileDescriptor` for exactly this reason. The factory in Task 7 extracts `pfd.fileDescriptor` before passing to WAV / AIFF encoders.

- [ ] **Step 5: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/WavPcmEncoder.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/WavPcmEncoderTest.kt
git commit -m "feat(android-audio): WAV/PCM file encoder"
```

---

## Task 9: AiffPcmEncoder

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AiffPcmEncoder.kt`
- Create: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AiffPcmEncoderTest.kt`
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/Ieee80BitFloat.kt` (helper for 80-bit IEEE 754 extended-precision sample rate encoding)

- [ ] **Step 1: Write failing tests (focused on AIFF/AIFC validity)**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.PcmBitDepth
import io.github.jiyimeta.sheetmusic.audio.model.PcmOptions
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

class AiffPcmEncoderTest {
    @Test fun stereoInt16ProducesFormAiffWithCommAndSsndChunks(@TempDir tmp: File) {
        val out = File(tmp, "test.aiff")
        val opts = PcmOptions(sampleRate = 44100, bitDepth = PcmBitDepth.Int16, channels = AudioChannelCount.Stereo)
        val raf = RandomAccessFile(out, "rw")
        AiffPcmEncoder(opts, 44100, raf.fd).use { enc ->
            enc.appendPcmFloat(floatArrayOf(0.5f), floatArrayOf(-0.5f), 1)
            enc.finish()
        }
        raf.close()
        val bytes = out.readBytes()
        assertEquals("FORM", String(bytes, 0, 4))
        assertEquals("AIFF", String(bytes, 8, 4))
        assertEquals("COMM", String(bytes, 12, 4))
        // COMM payload: channels(2) + numFrames(4) + sampleSize(2) + sampleRate(10) = 18
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        bb.position(20); assertEquals(2, bb.short.toInt())          // channels
        bb.position(22); assertEquals(1, bb.int)                    // numFrames
        bb.position(26); assertEquals(16, bb.short.toInt())         // sampleSize
    }

    @Test fun float32ProducesFormAifcWithFl32Compression(@TempDir tmp: File) {
        val out = File(tmp, "test.aifc")
        val opts = PcmOptions(sampleRate = 48000, bitDepth = PcmBitDepth.Float32, channels = AudioChannelCount.Stereo)
        val raf = RandomAccessFile(out, "rw")
        AiffPcmEncoder(opts, 48000, raf.fd).use { enc ->
            enc.appendPcmFloat(floatArrayOf(0.5f), floatArrayOf(-0.5f), 1)
            enc.finish()
        }
        raf.close()
        val bytes = out.readBytes()
        assertEquals("FORM", String(bytes, 0, 4))
        assertEquals("AIFC", String(bytes, 8, 4))
        // Look for "fl32" 4-cc somewhere after COMM
        val s = String(bytes, Charsets.ISO_8859_1)
        assertTrue(s.contains("fl32"))
    }
}

class Ieee80BitFloatTest {
    @Test fun encodes44100() {
        val bytes = Ieee80BitFloat.encode(44100.0)
        // Expected layout: BE 80-bit float. 44100.0 has exponent 14 (2^14 = 16384,
        // 44100/16384 ≈ 2.69, mantissa significand 0xAC44_0000_0000_0000).
        // Use the encoded form from a reference impl (Python:
        //   struct.pack('>HHHL', 0x400e, 0xac44, 0, 0)) — bytes ought to be
        //   40 0E AC 44 00 00 00 00 00 00.
        assertEquals(0x40.toByte(), bytes[0])
        assertEquals(0x0E.toByte(), bytes[1])
        assertEquals(0xAC.toByte(), bytes[2])
        assertEquals(0x44.toByte(), bytes[3])
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AiffPcmEncoderTest" --tests "*.Ieee80BitFloatTest"
```

Expected: compile error.

- [ ] **Step 3: Implement Ieee80BitFloat**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

internal object Ieee80BitFloat {
    /** Encode [value] as a big-endian 80-bit IEEE 754 extended-precision float. */
    fun encode(value: Double): ByteArray {
        require(value > 0) { "AIFF sample rate must be positive" }
        val out = ByteArray(10)
        if (value == 0.0) return out
        var m = value
        var exp = 0
        while (m < 1.0) { m *= 2.0; exp-- }
        while (m >= 2.0) { m /= 2.0; exp++ }
        val biasedExp = exp + 16383
        // Sign bit + 15-bit biased exponent
        out[0] = ((biasedExp shr 8) and 0x7F).toByte()
        out[1] = (biasedExp and 0xFF).toByte()
        // 64-bit mantissa, MSB set (since m is normalized ≥ 1.0)
        val mantissa = (m * (1L shl 63).toDouble()).toLong()
        for (i in 0 until 8) {
            out[2 + i] = ((mantissa ushr ((7 - i) * 8)) and 0xFF).toByte()
        }
        return out
    }
}
```

- [ ] **Step 4: Implement AiffPcmEncoder**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.PcmBitDepth
import io.github.jiyimeta.sheetmusic.audio.model.PcmOptions
import java.io.FileDescriptor
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal class AiffPcmEncoder(
    private val options: PcmOptions,
    sampleRate: Int,
    fd: FileDescriptor,
) : AudioFileEncoder {
    private val raf = RandomAccessFile(fd, "rw")
    private val mono = options.channels == AudioChannelCount.Mono
    private val isFloat = options.bitDepth == PcmBitDepth.Float32
    private val bytesPerSample: Int = when (options.bitDepth) {
        PcmBitDepth.Int16 -> 2
        PcmBitDepth.Int24 -> 3
        PcmBitDepth.Int32 -> 4
        PcmBitDepth.Float32 -> 4
    }
    private val frameBytes: Int = bytesPerSample * options.channels.rawValue
    private var frameCount: Int = 0
    private var finished = false
    private var dataChunkOffset: Long = 0

    init { writeHeader() }

    private fun writeHeader() {
        val formType = if (isFloat) "AIFC" else "AIFF"
        // FORM header
        raf.write("FORM".toByteArray())
        raf.write(beInt(0))             // FORM size — backfill
        raf.write(formType.toByteArray())
        // COMM chunk
        raf.write("COMM".toByteArray())
        val commPayloadSize = if (isFloat) 18 + 4 + 6 else 18  // +fl32 + pascal name "\x04fl32"
        raf.write(beInt(commPayloadSize))
        raf.write(beShort(options.channels.rawValue.toShort()))
        raf.write(beInt(0))             // numFrames — backfill
        raf.write(beShort((bytesPerSample * 8).toShort()))
        raf.write(Ieee80BitFloat.encode(options.sampleRate.toDouble()))
        if (isFloat) {
            raf.write("fl32".toByteArray())
            raf.write(byteArrayOf(0x04, 'f'.code.toByte(), 'l'.code.toByte(),
                                  '3'.code.toByte(), '2'.code.toByte(), 0))
        }
        // SSND chunk
        raf.write("SSND".toByteArray())
        raf.write(beInt(0))             // SSND size — backfill
        raf.write(beInt(0))             // offset = 0
        raf.write(beInt(0))             // blockSize = 0
        dataChunkOffset = raf.filePointer
    }

    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        val payload = ByteArray(frames * frameBytes)
        when (options.bitDepth) {
            PcmBitDepth.Int16 ->
                PcmSampleConversion.floatToInt16InterleavedBE(left, right, frames, mono, payload)
            PcmBitDepth.Int24 ->
                PcmSampleConversion.floatToInt24BE(left, right, frames, mono, payload)
            PcmBitDepth.Int32 ->
                PcmSampleConversion.floatToInt32BE(left, right, frames, mono, payload)
            PcmBitDepth.Float32 ->
                PcmSampleConversion.floatToFloat32BE(left, right, frames, mono, payload)
        }
        raf.write(payload)
        frameCount += frames
    }

    override fun finish() {
        if (finished) return
        val dataBytes = frameCount * frameBytes
        val ssndSize = 8 + dataBytes
        val formSize = (dataChunkOffset.toInt() + dataBytes) - 8
        // FORM size at offset 4
        raf.seek(4); raf.write(beInt(formSize))
        // COMM numFrames at offset 22
        raf.seek(22); raf.write(beInt(frameCount))
        // SSND size: COMM occupies offset 12..(20+commPayloadSize); SSND header starts after.
        // The location of "SSND size" is the 4 bytes right after "SSND" 4cc — find it
        // by knowing the COMM chunk's end:
        val commPayloadSize = if (isFloat) 18 + 4 + 6 else 18
        val ssndChunkHeaderOffset = (20 + commPayloadSize).toLong()
        raf.seek(ssndChunkHeaderOffset + 4); raf.write(beInt(ssndSize))
        raf.fd.sync()
        finished = true
    }

    override fun close() {
        raf.close()
    }

    private fun beShort(v: Short): ByteArray =
        ByteBuffer.allocate(2).order(ByteOrder.BIG_ENDIAN).putShort(v).array()

    private fun beInt(v: Int): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(v).array()
}
```

- [ ] **Step 5: Run tests**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AiffPcmEncoderTest" --tests "*.Ieee80BitFloatTest"
```

Expected: all PASS. If COMM chunk layout offsets fail, dump the resulting file with `xxd` and compare against a reference AIFF written by Apple's `afconvert`.

- [ ] **Step 6: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AiffPcmEncoder.kt \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/Ieee80BitFloat.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AiffPcmEncoderTest.kt
git commit -m "feat(android-audio): AIFF/AIFC file encoder + 80-bit IEEE 754 helper"
```

---

## Task 10: AacM4aEncoder

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AacM4aEncoder.kt`
- Create: `Android/SheetMusicAudioAndroid/src/androidTest/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AacM4aEncoderInstrumentedTest.kt`

(JVM unit tests don't cover MediaCodec; coverage is via instrumented tests in this task.)

- [ ] **Step 1: Write failing instrumented test**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import android.media.MediaMetadataRetriever
import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.CompressedOptions
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class AacM4aEncoderInstrumentedTest {
    @Test fun stereoAac128kbpsProducesValidM4a() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val out = File(ctx.cacheDir, "test.m4a")
        if (out.exists()) out.delete()
        val opts = CompressedOptions(sampleRate = 44100, bitRate = 128_000, channels = AudioChannelCount.Stereo)
        ParcelFileDescriptor.open(out, ParcelFileDescriptor.MODE_READ_WRITE or
            ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE).use { fd ->
            AacM4aEncoder(opts, 44100, fd).use { enc ->
                // 1 second of silence
                val left = FloatArray(4096)
                val right = FloatArray(4096)
                repeat(11) {  // ~45000 frames ≈ 1 sec at 44100
                    enc.appendPcmFloat(left, right, 4096)
                }
                enc.finish()
            }
        }
        // Validate with MediaMetadataRetriever.
        val retriever = MediaMetadataRetriever()
        retriever.setDataSource(out.absolutePath)
        val mime = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
        val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
        retriever.release()
        assertTrue("mime should be MP4/M4A audio", mime?.contains("mp4") == true || mime?.contains("m4a") == true)
        assertTrue("duration should be ~1 second", durationMs in 800..1200)
    }
}
```

- [ ] **Step 2: Implement**

This is a substantial encoder. The full structure:

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.CompressedOptions
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal class AacM4aEncoder(
    private val options: CompressedOptions,
    private val sampleRate: Int,
    fd: ParcelFileDescriptor,
) : AudioFileEncoder {
    private val codec: MediaCodec
    private val muxer: MediaMuxer
    private val mono = options.channels == AudioChannelCount.Mono
    private var trackIndex: Int = -1
    private var muxerStarted = false
    private var accumulatedFrames: Long = 0
    private var finished = false
    private val bufferInfo = MediaCodec.BufferInfo()

    init {
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC, options.sampleRate, options.channels.rawValue,
        )
        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        format.setInteger(MediaFormat.KEY_BIT_RATE, options.bitRate)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192 * 2)
        codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        muxer = MediaMuxer(fd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        val tmp = ShortArray(frames * options.channels.rawValue)
        PcmSampleConversion.floatToInt16Interleaved(left, right, frames, mono, tmp)
        val bytes = ByteArray(tmp.size * 2)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(tmp)
        feedEncoder(bytes, accumulatedFrames * 1_000_000L / sampleRate, false)
        accumulatedFrames += frames
        drainEncoder(false)
    }

    private fun feedEncoder(payload: ByteArray, ptsUs: Long, endOfStream: Boolean) {
        while (true) {
            val inputIndex = codec.dequeueInputBuffer(10_000)
            if (inputIndex < 0) continue
            val inputBuffer = codec.getInputBuffer(inputIndex) ?: return
            inputBuffer.clear()
            inputBuffer.put(payload)
            val flags = if (endOfStream) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
            codec.queueInputBuffer(inputIndex, 0, payload.size, ptsUs, flags)
            return
        }
    }

    private fun drainEncoder(endOfStream: Boolean) {
        while (true) {
            val outIndex = codec.dequeueOutputBuffer(bufferInfo, if (endOfStream) 10_000 else 0)
            when {
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                }
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    trackIndex = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxerStarted = true
                }
                outIndex >= 0 -> {
                    val outBuffer = codec.getOutputBuffer(outIndex) ?: continue
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        // Skip codec config; muxer reads it via outputFormat instead.
                        codec.releaseOutputBuffer(outIndex, false)
                        continue
                    }
                    if (muxerStarted && bufferInfo.size > 0) {
                        outBuffer.position(bufferInfo.offset)
                        outBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        muxer.writeSampleData(trackIndex, outBuffer, bufferInfo)
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                }
            }
        }
    }

    override fun finish() {
        if (finished) return
        feedEncoder(ByteArray(0), accumulatedFrames * 1_000_000L / sampleRate, true)
        drainEncoder(true)
        if (muxerStarted) {
            muxer.stop()
        }
        muxer.release()
        codec.stop()
        codec.release()
        finished = true
    }

    override fun close() {
        if (!finished) {
            try { codec.stop() } catch (_: Throwable) {}
            try { codec.release() } catch (_: Throwable) {}
            try { muxer.release() } catch (_: Throwable) {}
        }
    }
}
```

- [ ] **Step 3: Run instrumented test on emulator**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:connectedDebugAndroidTest \
    --tests "*.AacM4aEncoderInstrumentedTest"
```

Expected: PASS. The test writes ~1 second of silence; the output should be a valid M4A.

- [ ] **Step 4: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AacM4aEncoder.kt \
        Android/SheetMusicAudioAndroid/src/androidTest/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AacM4aEncoderInstrumentedTest.kt
git commit -m "feat(android-audio): AAC/M4A file encoder via MediaCodec + MediaMuxer"
```

---

## Task 11: Mp3MediaCodecEncoder

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/Mp3MediaCodecEncoder.kt`
- Create: `Android/SheetMusicAudioAndroid/src/androidTest/kotlin/io/github/jiyimeta/sheetmusic/audio/export/Mp3MediaCodecEncoderInstrumentedTest.kt`

- [ ] **Step 1: Write failing instrumented test**

```kotlin
@RunWith(AndroidJUnit4::class)
class Mp3MediaCodecEncoderInstrumentedTest {
    @Test fun mp3EncoderEitherWritesValidMp3OrThrowsFormatUnsupported() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val out = File(ctx.cacheDir, "test.mp3")
        if (out.exists()) out.delete()
        val opts = CompressedOptions(sampleRate = 44100, bitRate = 128_000, channels = AudioChannelCount.Stereo)
        try {
            ParcelFileDescriptor.open(out, ParcelFileDescriptor.MODE_READ_WRITE or
                ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE).use { fd ->
                Mp3MediaCodecEncoder(opts, 44100, fd).use { enc ->
                    val left = FloatArray(4096); val right = FloatArray(4096)
                    repeat(11) { enc.appendPcmFloat(left, right, 4096) }
                    enc.finish()
                }
            }
            assertTrue("file should exist and be non-trivial", out.length() > 1000)
            // First two bytes should be MP3 frame sync (0xFF 0xFB or 0xFF 0xFA)
            val first = out.inputStream().use { it.readNBytes(2) }
            assertEquals(0xFF.toByte(), first[0])
            assertTrue((first[1].toInt() and 0xE0) == 0xE0)
        } catch (e: AudioBackendException.FormatUnsupportedOnThisOS) {
            // Acceptable on devices without MP3 encoder (AOSP doesn't mandate one).
        }
    }
}
```

- [ ] **Step 2: Implement**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.CompressedOptions
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal class Mp3MediaCodecEncoder(
    private val options: CompressedOptions,
    private val sampleRate: Int,
    fd: ParcelFileDescriptor,
) : AudioFileEncoder {
    private val codec: MediaCodec
    private val output: FileOutputStream
    private val mono = options.channels == AudioChannelCount.Mono
    private var accumulatedFrames: Long = 0
    private var finished = false
    private val bufferInfo = MediaCodec.BufferInfo()

    init {
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_MPEG, options.sampleRate, options.channels.rawValue,
        )
        format.setInteger(MediaFormat.KEY_BIT_RATE, options.bitRate)
        val codecName = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            ?: throw AudioBackendException.FormatUnsupportedOnThisOS(AudioFileFormat.Mp3(options))
        codec = MediaCodec.createByCodecName(codecName)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        output = FileOutputStream(fd.fileDescriptor)
    }

    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        val tmp = ShortArray(frames * options.channels.rawValue)
        PcmSampleConversion.floatToInt16Interleaved(left, right, frames, mono, tmp)
        val bytes = ByteArray(tmp.size * 2)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(tmp)
        feedEncoder(bytes, accumulatedFrames * 1_000_000L / sampleRate, false)
        accumulatedFrames += frames
        drainEncoder(false)
    }

    private fun feedEncoder(payload: ByteArray, ptsUs: Long, endOfStream: Boolean) {
        while (true) {
            val inIdx = codec.dequeueInputBuffer(10_000)
            if (inIdx < 0) continue
            val buf = codec.getInputBuffer(inIdx) ?: return
            buf.clear(); buf.put(payload)
            codec.queueInputBuffer(inIdx, 0, payload.size, ptsUs,
                if (endOfStream) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
            return
        }
    }

    private fun drainEncoder(endOfStream: Boolean) {
        while (true) {
            val outIdx = codec.dequeueOutputBuffer(bufferInfo, if (endOfStream) 10_000 else 0)
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { /* no muxer */ }
                outIdx >= 0 -> {
                    val buf = codec.getOutputBuffer(outIdx) ?: continue
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        codec.releaseOutputBuffer(outIdx, false); continue
                    }
                    if (bufferInfo.size > 0) {
                        val out = ByteArray(bufferInfo.size)
                        buf.position(bufferInfo.offset)
                        buf.get(out, 0, bufferInfo.size)
                        output.write(out)
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                }
            }
        }
    }

    override fun finish() {
        if (finished) return
        feedEncoder(ByteArray(0), accumulatedFrames * 1_000_000L / sampleRate, true)
        drainEncoder(true)
        output.flush(); output.fd.sync()
        codec.stop(); codec.release()
        finished = true
    }

    override fun close() {
        try { if (!finished) codec.stop() } catch (_: Throwable) {}
        try { codec.release() } catch (_: Throwable) {}
        try { output.close() } catch (_: Throwable) {}
    }
}
```

- [ ] **Step 3: Run instrumented test**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:connectedDebugAndroidTest \
    --tests "*.Mp3MediaCodecEncoderInstrumentedTest"
```

Expected: PASS (either MP3 output or `FormatUnsupportedOnThisOS` caught).

- [ ] **Step 4: Commit (including Task 7's AudioFileEncoder.kt)**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioFileEncoder.kt \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/Mp3MediaCodecEncoder.kt \
        Android/SheetMusicAudioAndroid/src/androidTest/kotlin/io/github/jiyimeta/sheetmusic/audio/export/Mp3MediaCodecEncoderInstrumentedTest.kt
git commit -m "feat(android-audio): MP3 encoder via MediaCodec + AudioFileEncoder factory"
```

---

## Task 12: ExportEngineSnapshot model + helpers

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/ExportEngineSnapshot.kt`

- [ ] **Step 1: Write the data class (small, no tests needed — covered by AudioExporterTest later)**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel

/**
 * Snapshot of mutable engine state captured at the top of an export call.
 * The export pipeline reads this; the live engine is not touched.
 */
internal data class ExportEngineSnapshot(
    val mixerChannels: List<MixerChannel>,
    val metronomeEnabled: Boolean,
    val metronomeVolume: Float,
    val metronomeBeats: List<MetronomeBeat>,
    val rate: Float,
)
```

- [ ] **Step 2: Commit (will be exercised by Task 13)**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/ExportEngineSnapshot.kt
git commit -m "feat(android-audio): ExportEngineSnapshot data class"
```

---

## Task 13: AudioExporter render loop

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioExporter.kt`
- Create: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioExporterTest.kt`
- Create: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/fakes/FakeAudioFileEncoder.kt`

- [ ] **Step 1: Write failing test using existing fake driver**

The existing `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/fakes/` dir already has FakeSynthDriver / FakePlayerDriver — confirm by listing. Extend them if needed.

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.export.fakes.FakeAudioFileEncoder
import io.github.jiyimeta.sheetmusic.audio.fakes.FakePlayerDriver
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeSynthDriver
import io.github.jiyimeta.sheetmusic.audio.fakes.StubSoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class AudioExporterTest {
    private val snapshot = ExportEngineSnapshot(
        mixerChannels = listOf(
            MixerChannel(staffIndex = 0, displayName = "Staff 1", program = 0),
        ),
        metronomeEnabled = false,
        metronomeVolume = 1.0f,
        metronomeBeats = emptyList(),
        rate = 1.0f,
    )

    private val staffParams = listOf(
        StaffParams(staffIndex = 0, bankLSB = 0, program = 0, isDrums = false, partAddressHash = 0L),
    )

    @Test fun renderLoopTerminatesAtEndTick() = runTest {
        val encoder = FakeAudioFileEncoder()
        val synth = FakeSynthDriver(advanceTicksPerCall = 480)
        val player = FakePlayerDriver(startTick = 0)
        val exporter = AudioExporter(
            resolver = StubSoundfontResolver(),
            context = null,
            synthFactory = { synth },
            playerFactory = { player },
            encoderFactory = { _, _, _ -> encoder },
        )
        exporter.run(
            outputFd = null,  // FakeAudioFileEncoder ignores fd
            smfBytes = ByteArray(16),
            staffParams = staffParams,
            snapshot = snapshot,
            startTick = 0,
            endTick = 1920,
            ticksPerBeat = 480,
            format = AudioFileFormat.Wav(),
            sampleRate = 48000,
            progress = null,
        )
        assertEquals(true, encoder.finished, "encoder.finish() should have been called")
        assertTrue(encoder.totalFramesWritten > 0)
        assertTrue(player.lastTick >= 1920, "player should have advanced to endTick")
    }

    @Test fun emptyRangeWritesHeaderOnly() = runTest {
        val encoder = FakeAudioFileEncoder()
        val synth = FakeSynthDriver(advanceTicksPerCall = 480)
        val player = FakePlayerDriver(startTick = 0)
        val exporter = AudioExporter(
            resolver = StubSoundfontResolver(),
            context = null,
            synthFactory = { synth },
            playerFactory = { player },
            encoderFactory = { _, _, _ -> encoder },
        )
        exporter.run(
            outputFd = null, smfBytes = ByteArray(16), staffParams = staffParams,
            snapshot = snapshot, startTick = 0, endTick = 0,
            ticksPerBeat = 480, format = AudioFileFormat.Wav(),
            sampleRate = 48000, progress = null,
        )
        assertEquals(true, encoder.finished)
        assertEquals(0, encoder.totalFramesWritten)
    }

    @Test fun progressIsEmittedDuringRender() = runTest {
        val encoder = FakeAudioFileEncoder()
        val synth = FakeSynthDriver(advanceTicksPerCall = 480)
        val player = FakePlayerDriver(startTick = 0)
        val progressValues = mutableListOf<Float>()
        AudioExporter(
            resolver = StubSoundfontResolver(),
            context = null,
            synthFactory = { synth },
            playerFactory = { player },
            encoderFactory = { _, _, _ -> encoder },
        ).run(
            outputFd = null, smfBytes = ByteArray(16), staffParams = staffParams,
            snapshot = snapshot, startTick = 0, endTick = 4800,
            ticksPerBeat = 480, format = AudioFileFormat.Wav(),
            sampleRate = 48000, progress = { p -> progressValues.add(p) },
        )
        assertTrue(progressValues.isNotEmpty())
        assertEquals(1.0f, progressValues.last(), 0.001f)
    }
}
```

`FakeAudioFileEncoder`:

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export.fakes

import io.github.jiyimeta.sheetmusic.audio.export.AudioFileEncoder

internal class FakeAudioFileEncoder : AudioFileEncoder {
    var totalFramesWritten: Int = 0
    var finished: Boolean = false
    var closed: Boolean = false
    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        totalFramesWritten += frames
    }
    override fun finish() { finished = true }
    override fun close() { closed = true }
}
```

If `FakeSynthDriver` and `FakePlayerDriver` don't have constructors that accept `advanceTicksPerCall` / `startTick`, extend them to expose enough surface for this test. They already exist for the Phase 5 sub-project A loop tests.

- [ ] **Step 2: Verify fail**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AudioExporterTest"
```

Expected: compile error.

- [ ] **Step 3: Implement AudioExporter**

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

import android.content.Context
import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
import io.github.jiyimeta.sheetmusic.audio.synth.FluidSynthDriver
import io.github.jiyimeta.sheetmusic.audio.synth.PlayerDriver
import io.github.jiyimeta.sheetmusic.audio.synth.SynthDriver
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext

internal class AudioExporter(
    private val resolver: SoundfontResolver,
    private val context: Context?,
    private val synthFactory: (Int) -> SynthDriver = { FluidSynthDriver.create(it) },
    private val playerFactory: (Long) -> PlayerDriver = { PlayerDriver(it) },
    private val encoderFactory: (AudioFileFormat, Int, ParcelFileDescriptor?) -> AudioFileEncoder =
        { fmt, sr, fd -> AudioFileEncoder.create(fmt, sr, fd!!) },
) {
    companion object {
        const val BUFFER_FRAMES = 4096
        private const val PROGRESS_EMIT_INTERVAL_MS = 33L
    }

    suspend fun run(
        outputFd: ParcelFileDescriptor?,
        smfBytes: ByteArray,
        staffParams: List<StaffParams>,
        snapshot: ExportEngineSnapshot,
        startTick: Long,
        endTick: Long,
        ticksPerBeat: Int,
        format: AudioFileFormat,
        sampleRate: Int,
        progress: ((Float) -> Unit)?,
    ) {
        val synth = synthFactory(sampleRate)
        val player = playerFactory(synth.nativeHandle)
        val encoder = encoderFactory(format, sampleRate, outputFd)
        var lastProgressEmitMs = 0L
        try {
            // Load SF2 + apply per-staff programs.
            val uri = resolver.defaultGmSoundfontUri
                ?: (staffParams.firstOrNull()?.let {
                    resolver.soundfontUriFor(it.bankLSB, it.program, it.isDrums)
                })
            val sfid = uri?.let { synth.loadSoundFont(it, context) } ?: -1
            if (sfid >= 0) {
                for (p in staffParams) {
                    if (p.isDrums) synth.setChannelType(p.staffIndex, isDrum = true)
                    val effectiveBank = if (p.isDrums) 128 else p.bankLSB
                    val mixerProgram = snapshot.mixerChannels
                        .firstOrNull { it.staffIndex == p.staffIndex }?.program ?: p.program
                    synth.programSelect(sfid, p.staffIndex, effectiveBank, mixerProgram.coerceIn(0, 127))
                }
                // Apply mixer volume / mute / solo.
                val soloed = snapshot.mixerChannels.any { it.isSoloed }
                for (chan in snapshot.mixerChannels) {
                    val audible = if (soloed) chan.isSoloed else !chan.isMuted
                    val gain = if (audible) chan.volume else 0f
                    synth.cc(chan.staffIndex, 7, (gain * 127).toInt().coerceIn(0, 127))
                }
            }
            if (player.load(smfBytes) != 0) {
                throw AudioBackendException.EngineSetupFailed("player.load returned non-zero")
            }
            if (snapshot.rate != 1.0f) player.setTempo(snapshot.rate.toDouble())
            player.seekTick(startTick)
            player.play()

            val left = FloatArray(BUFFER_FRAMES)
            val right = FloatArray(BUFFER_FRAMES)
            val totalTicks = (endTick - startTick).coerceAtLeast(0)
            while (player.currentTick < endTick) {
                coroutineContext.ensureActive()
                val ticksRemaining = endTick - player.currentTick
                val framesRemaining = ticksToFrames(
                    ticksRemaining, ticksPerBeat, snapshot.rate, sampleRate,
                ).coerceAtLeast(1)
                val frames = minOf(BUFFER_FRAMES, framesRemaining.toInt())
                synth.writeFloat(frames, left, right)
                encoder.appendPcmFloat(left, right, frames)
                val nowMs = System.currentTimeMillis()
                if (progress != null && nowMs - lastProgressEmitMs >= PROGRESS_EMIT_INTERVAL_MS) {
                    val done = (player.currentTick - startTick).toDouble() / totalTicks.toDouble()
                    progress(done.coerceIn(0.0, 1.0).toFloat())
                    lastProgressEmitMs = nowMs
                }
            }
            encoder.finish()
            progress?.invoke(1.0f)
        } catch (c: CancellationException) {
            throw AudioBackendException.Cancelled().apply { initCause(c) }
        } finally {
            try { player.close() } catch (_: Throwable) {}
            try { synth.close() } catch (_: Throwable) {}
            try { encoder.close() } catch (_: Throwable) {}
        }
    }

    private fun ticksToFrames(
        ticks: Long, ticksPerBeat: Int, rate: Float, sampleRate: Int,
    ): Long {
        // beatsPerSecond at native tempo is unknown here (it lives in the SMF).
        // Approximate using rate as a scaling factor and assume the player has
        // already absorbed the SMF tempo via setTempo. The frame budget here
        // is just an upper bound on the next buffer; the loop terminates on
        // player.currentTick anyway, so a coarse estimate is fine.
        val beats = ticks.toDouble() / ticksPerBeat.toDouble()
        // Assume 120 BPM as a fallback; actual rate is applied by setTempo.
        val seconds = beats / 2.0 / rate.toDouble()
        return (seconds * sampleRate.toDouble()).toLong()
    }
}
```

If `SynthDriver` doesn't expose `setChannelType` / `programSelect` / `cc` directly, the corresponding helpers live on `FluidSynthEngine` instead — refactor those out into a shared extension function that both `FluidSynthEngine.setupStaves` and `AudioExporter.run` can call. Don't duplicate the staff setup logic.

- [ ] **Step 4: Run tests**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AudioExporterTest"
```

Expected: 3/3 PASS.

- [ ] **Step 5: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioExporter.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioExporterTest.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/fakes/FakeAudioFileEncoder.kt
git commit -m "feat(android-audio): AudioExporter offline render loop"
```

---

## Task 14: `AndroidPlaybackEngine.exportAudioFile`

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt`
- Modify: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineTest.kt` (add export-flow assertions)

- [ ] **Step 1: Add failing test**

In `AndroidPlaybackEngineTest.kt`:

```kotlin
@Test fun exportAudioFileSetsExportingStateAndCallsExporter() = runTest {
    val engine = makeEngine(/* existing fixture helper */)
    engine.prepare(scoreHandle = 1L)
    var sawExporting = false
    val collector = launch { engine.state.collect { if (it == PlaybackState.EXPORTING) sawExporting = true } }
    engine.exportAudioFile(
        outputFd = nullStubFd(),
        scoreHandle = 1L,
        format = AudioFileFormat.Wav(),
    )
    assertTrue(sawExporting)
    assertEquals(PlaybackState.STOPPED, engine.state.value)
    collector.cancel()
}

@Test fun exportAudioFileWithUnknownHandleThrowsNoScorePrepared() = runTest {
    val engine = makeEngine(/* fixture */)
    val fd = nullStubFd()
    val ex = assertThrows<AudioBackendException.NoScorePrepared> {
        engine.exportAudioFile(fd, scoreHandle = 999L, format = AudioFileFormat.Wav())
    }
    assertTrue(ex.message!!.contains("No score"))
}
```

Provide `nullStubFd()` as a small helper that returns a `ParcelFileDescriptor` to `/dev/null` (Android dev/null) or `ParcelFileDescriptor.createPipe()[1]`.

- [ ] **Step 2: Verify fail**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AndroidPlaybackEngineTest"
```

Expected: compile error — `exportAudioFile` doesn't exist.

- [ ] **Step 3: Implement on AndroidPlaybackEngine**

Add to `AndroidPlaybackEngine.kt`:

```kotlin
private val exportMutex = Mutex()

/**
 * Offline-render the prepared score to an audio file at [outputFd].
 * See spec docs/superpowers/specs/2026-05-20-android-audio-file-export-design.md
 * for full lifecycle / cancellation / error contract.
 */
suspend fun exportAudioFile(
    outputFd: ParcelFileDescriptor,
    scoreHandle: Long,
    format: AudioFileFormat,
    range: AudioExportRange = AudioExportRange.Full,
    progress: ((Float) -> Unit)? = null,
) {
    exportMutex.withLock {
        if (this.scoreHandle == 0L || this.scoreHandle != scoreHandle) {
            throw AudioBackendException.NoScorePrepared()
        }
        // Resolve tick range.
        // CurrentLoop is resolved in Kotlin using the live _loopRange — the JNI
        // seam doesn't know about engine state. Full / Region / RegionThroughEnd
        // go through the JNI seam (the timeline lives on the Swift side).
        val (startTick, endTick) = when (range) {
            is AudioExportRange.CurrentLoop -> {
                val loop = _loopRange.value
                if (loop != null) Pair(loop.startTick, loop.endTick)
                else Pair(0L, totalTicks)
            }
            else -> {
                val rangeBytes = AudioExportRangeEncoder.encode(range)
                val resolved = jniBridge.resolveExportTickRange(scoreHandle, rangeBytes)
                if (resolved.size < 2 || resolved[0] < 0 || resolved[1] < 0) {
                    throw AudioBackendException.RangeNotInTimeline()
                }
                Pair(resolved[0], resolved[1])
            }
        }

        // Capture snapshot.
        val snapshot = ExportEngineSnapshot(
            mixerChannels = _mixerChannels.value,
            metronomeEnabled = metronomeMixer?.isEnabled ?: false,
            metronomeVolume = metronomeMixer?.volume ?: 1f,
            metronomeBeats = metronomeMixer?.beats ?: emptyList(),
            rate = _currentRate.value,
        )

        // Re-render the SMF (including the metronome track if enabled) — same
        // logic the live engine uses in prepare(), refactored into a shared
        // helper if it isn't already.
        val smfBytes = jniBridge.renderMidi(scoreHandle)
        // Staff params.
        val staffParams = StaffParamsDecoder.decodeArray(jniBridge.staffParams(scoreHandle))
        // ticksPerBeat from prepare()'s timeline summary cache. Use the
        // existing field if you stored it; otherwise re-call jniBridge.timelineSummary.
        val summary = jniBridge.timelineSummary(scoreHandle)
        val ticksPerBeat = summary[2].toInt()

        _state.value = PlaybackState.EXPORTING
        try {
            val exporter = AudioExporter(
                resolver = soundfontResolver,
                context = context,
                synthFactory = synthFactory,
                playerFactory = playerFactory,
            )
            exporter.run(
                outputFd = outputFd,
                smfBytes = smfBytes,
                staffParams = staffParams,
                snapshot = snapshot,
                startTick = startTick,
                endTick = endTick,
                ticksPerBeat = ticksPerBeat,
                format = format,
                sampleRate = 48_000,
                progress = progress,
            )
        } finally {
            _state.value = PlaybackState.STOPPED
        }
    }
}
```

Add the new JNI seam method to the `JniBridge` interface:

```kotlin
fun resolveExportTickRange(scoreHandle: Long, rangeBytes: ByteArray): LongArray
```

And to `defaultBridge`:

```kotlin
override fun resolveExportTickRange(h: Long, bytes: ByteArray) =
    SheetMusicAudioJNI.nativeResolveExportTickRange(h, bytes)
```

If `MetronomeMixer.beats` / `MetronomeMixer.volume` / `MetronomeMixer.isEnabled` aren't exposed, add the getters — they're already needed by `prepare()` so likely already public.

- [ ] **Step 4: Update `FakeJniBridge` if used by tests**

In whichever fake file the existing tests use, add the new method returning a fixed value (e.g., `LongArray(2) { 0L; 1920L }`).

- [ ] **Step 5: Run tests**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test --tests "*.AndroidPlaybackEngineTest"
```

Expected: PASS.

- [ ] **Step 6: Cross-compile Swift side**

```bash
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
    swift build --swift-sdk aarch64-unknown-linux-android28
```

Expected: succeeds.

- [ ] **Step 7: Commit**

```bash
git add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt \
        Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineTest.kt
git commit -m "feat(android-audio): AndroidPlaybackEngine.exportAudioFile public API"
```

---

## Task 15: Compose demo Export UI

**Files:**
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/export/ExportFormatOption.kt`
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/export/ExportState.kt`
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/export/ExportViewModel.kt`
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/AudioControls.kt` (or wherever the current audio controls live) to add the Export button

This is a UI task; visual verification is by running the app on the emulator.

- [ ] **Step 1: `ExportFormatOption.kt`**

```kotlin
package com.example.sheetmusic.export

import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.CompressedOptions
import io.github.jiyimeta.sheetmusic.audio.model.PcmOptions

enum class ExportFormatOption(
    val displayName: String,
    val mime: String,
    val extension: String,
) {
    Wav("WAV", "audio/wav", ".wav"),
    Aiff("AIFF", "audio/aiff", ".aiff"),
    M4a("M4A (AAC)", "audio/mp4", ".m4a"),
    Mp3("MP3", "audio/mpeg", ".mp3");

    fun toAudioFileFormat(): AudioFileFormat = when (this) {
        Wav -> AudioFileFormat.Wav(PcmOptions())
        Aiff -> AudioFileFormat.Aiff(PcmOptions())
        M4a -> AudioFileFormat.M4a(CompressedOptions())
        Mp3 -> AudioFileFormat.Mp3(CompressedOptions())
    }
}
```

- [ ] **Step 2: `ExportState.kt`**

```kotlin
package com.example.sheetmusic.export

import android.net.Uri

sealed interface ExportState {
    object Idle : ExportState
    data class Running(val progress: Float) : ExportState
    data class Done(val uri: Uri) : ExportState
    data class Failed(val message: String) : ExportState
}
```

- [ ] **Step 3: `ExportViewModel.kt`**

```kotlin
package com.example.sheetmusic.export

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class ExportViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow<ExportState>(ExportState.Idle)
    val state: StateFlow<ExportState> = _state.asStateFlow()

    private var exportJob: Job? = null

    fun start(
        playbackEngine: AndroidPlaybackEngine,
        scoreHandle: Long,
        uri: Uri,
        format: AudioFileFormat,
    ) {
        cancel()
        exportJob = viewModelScope.launch(Dispatchers.IO) {
            val resolver = getApplication<Application>().contentResolver
            val pfd = resolver.openFileDescriptor(uri, "w")
            if (pfd == null) {
                _state.value = ExportState.Failed("Could not open output URI for writing")
                return@launch
            }
            _state.value = ExportState.Running(0f)
            try {
                pfd.use { fd ->
                    playbackEngine.exportAudioFile(
                        outputFd = fd,
                        scoreHandle = scoreHandle,
                        format = format,
                        progress = { p -> _state.value = ExportState.Running(p) },
                    )
                }
                _state.value = ExportState.Done(uri)
            } catch (c: CancellationException) {
                resolver.delete(uri, null, null)
                _state.value = ExportState.Idle
            } catch (e: Throwable) {
                resolver.delete(uri, null, null)
                _state.value = ExportState.Failed(e.message ?: e.javaClass.simpleName)
            }
        }
    }

    fun cancel() {
        exportJob?.cancel()
        exportJob = null
    }
}
```

- [ ] **Step 4: Wire Export button into existing audio controls**

Find the current home of the audio controls (likely `AudioControls.kt` or `ScoreView.kt`'s audio strip). Add:

```kotlin
val exportVm: ExportViewModel = viewModel()
var showFormatPicker by remember { mutableStateOf(false) }
var pendingFormat by remember { mutableStateOf<ExportFormatOption?>(null) }
val launcher = rememberLauncherForActivityResult(
    contract = ActivityResultContracts.CreateDocument(pendingFormat?.mime ?: "audio/wav"),
) { uri ->
    if (uri != null && pendingFormat != null) {
        exportVm.start(playbackEngine, scoreHandle, uri, pendingFormat!!.toAudioFileFormat())
    }
    pendingFormat = null
}

IconButton(onClick = { showFormatPicker = true }) {
    Icon(Icons.Default.Save, contentDescription = "Export audio")
}

if (showFormatPicker) {
    AlertDialog(
        onDismissRequest = { showFormatPicker = false },
        title = { Text("Export format") },
        text = {
            Column {
                ExportFormatOption.values().forEach { opt ->
                    TextButton(onClick = {
                        showFormatPicker = false
                        pendingFormat = opt
                        launcher.launch("score${opt.extension}")
                    }) { Text(opt.displayName) }
                }
            }
        },
        confirmButton = {},
    )
}

val exportState by exportVm.state.collectAsState()
when (val s = exportState) {
    is ExportState.Running -> {
        AlertDialog(
            onDismissRequest = {},
            title = { Text("Exporting…") },
            text = {
                Column {
                    LinearProgressIndicator(progress = { s.progress }, modifier = Modifier.fillMaxWidth())
                    Spacer(Modifier.height(8.dp))
                    Text("${(s.progress * 100).toInt()}%")
                }
            },
            confirmButton = {
                TextButton(onClick = { exportVm.cancel() }) { Text("Cancel") }
            },
        )
    }
    is ExportState.Done -> {
        // Snackbar / one-shot toast — wire via SnackbarHostState in MainActivity / SheetMusicApp
    }
    is ExportState.Failed -> {
        AlertDialog(onDismissRequest = {},
            title = { Text("Export failed") }, text = { Text(s.message) },
            confirmButton = { TextButton(onClick = {}) { Text("OK") } })
    }
    ExportState.Idle -> {}
}
```

(Exact wiring details depend on the existing demo structure — fit into the existing pattern.)

- [ ] **Step 5: Build the demo APK**

```bash
cd Examples/Android && ./gradlew :app:assembleDebug
```

Expected: BUILD SUCCESSFUL. (If new library code from the worktree needs to be installed locally for Maven resolution to work, follow the publish-local procedure documented in `Android/SheetMusicAndroid/README.md` first.)

- [ ] **Step 6: Commit**

```bash
git add Examples/Android/app/src/main/java/com/example/sheetmusic/export/ \
        Examples/Android/app/src/main/java/com/example/sheetmusic/AudioControls.kt
git commit -m "feat(android-example): Export UI with SAF format picker + progress dialog"
```

---

## Task 16: End-to-end emulator verification

**Files:**
- Modify: `Examples/Android/SMOKE_TEST.md` — add export-flow smoke steps

- [ ] **Step 1: Build & cross-compile native libs**

```bash
Scripts/android-build-libs.sh
```

Expected: arm64-v8a + x86_64 `libSheetMusicJNI.so` staged. Build succeeds.

- [ ] **Step 2: Stage test assets**

```bash
Scripts/android-bundle-test-score.sh
```

Expected: `~/Desktop/test.mscz` and `~/Desktop/gm.sf2` copied into `Examples/Android/app/src/main/assets/`.

- [ ] **Step 3: Install and launch on emulator (Pixel 6 Pro API 36)**

```bash
adb -s emulator-5554 install -r Examples/Android/app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 shell am start -n com.example.sheetmusic/.MainActivity
```

Wait for parse to complete (Play button enables).

- [ ] **Step 4: Export each format**

Manual:
1. Tap Export → choose WAV → save to Downloads/score.wav. Wait until progress reaches 100%, dialog dismisses.
2. Repeat for AIFF, M4A, MP3.

```bash
adb -s emulator-5554 pull /sdcard/Download/score.wav /tmp/score.wav
adb -s emulator-5554 pull /sdcard/Download/score.aiff /tmp/score.aiff
adb -s emulator-5554 pull /sdcard/Download/score.m4a /tmp/score.m4a
adb -s emulator-5554 pull /sdcard/Download/score.mp3 /tmp/score.mp3  # may not exist on devices without MP3 encoder

ffprobe /tmp/score.wav 2>&1 | grep -E "Duration|Audio:"
ffprobe /tmp/score.aiff 2>&1 | grep -E "Duration|Audio:"
ffprobe /tmp/score.m4a 2>&1 | grep -E "Duration|Audio:"
ffprobe /tmp/score.mp3 2>&1 | grep -E "Duration|Audio:" || echo "(mp3 may have failed if no encoder)"
```

Expected: each file's duration is within ~1 second of the macOS reference export's duration. Audio codec line confirms format.

- [ ] **Step 5: Cancellation smoke**

Manual: trigger an export, hit Cancel mid-render, confirm the file is removed from Downloads and the state goes back to Idle.

- [ ] **Step 6: Update SMOKE_TEST.md**

Add the export-flow steps to `Examples/Android/SMOKE_TEST.md` under a new "## Audio file export" section.

- [ ] **Step 7: Commit**

```bash
git add Examples/Android/SMOKE_TEST.md
git commit -m "docs(android-example): SMOKE_TEST steps for audio file export"
```

---

## Final review

- [ ] Run the full test suite:

```bash
swift test 2>&1 | tail -5
cd Android && ./gradlew :SheetMusicAudioAndroid:test
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
    swift build --swift-sdk aarch64-unknown-linux-android28
```

All three should be green.

- [ ] Run swiftlint:

```bash
swiftlint --quiet Sources Tests
```

Expected: 0 warnings/errors.

- [ ] Verify Apple Example builds:

```bash
cd Example && xcodegen generate && \
    xcodebuild -project SheetMusicExample.xcodeproj -scheme SheetMusicExample \
    -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
xcodebuild -project Example/SheetMusicExample.xcodeproj -scheme SheetMusicExampleMac \
    -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED for both.

When all of the above passes, the worktree is ready for the `superpowers:finishing-a-development-branch` skill to choose the merge strategy.
