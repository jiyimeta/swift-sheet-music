# Android audio backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Kotlin Gradle module `SheetMusicAudioAndroid` (`.aar`) that mirrors `SheetMusicAudioApple`'s `PlaybackEngine` API on Android, backed by FluidSynth + Oboe, plus a thin Swift JNI bridge (`AudioMidiBridge.swift`) inside the existing Phase 4 `SheetMusicAndroidJNI` target.

**Architecture:** Per spec `docs/superpowers/specs/2026-05-19-android-audio-backend-design.md`. Swift bridge exposes 8 `@_cdecl` functions (MIDI rendering, PlaybackTimeline lookups, staff params). Kotlin module owns playback: per-staff `fluid_synth_t` driven by one `fluid_player_t` with SMF channel-relabeled to encode track index. Compose app consumes via Gradle composite `includeBuild`.

**Tech Stack:** Swift 6.3.2 (Android SDK); Kotlin 1.9.x / AGP 8.x; FluidSynth via `dev.atsushieno:fluidsynth-android` (Maven, LGPL); Oboe via `com.google.oboe:oboe:1.9.0` (Apache-2.0); Swift Testing; JUnit4.

**Prerequisites:** Phase 4 non-audio (`worktree-android-compose-example` branch) MUST be merged to `main` before starting Task 1. The plan references `Sources/SheetMusicAndroidJNI/HandleTable.swift`, `JNISymbols.swift`, `DrawProgramEncoder.swift`, `Examples/Android/`, `Scripts/android-build-libs.sh`, and `Scripts/android-bundle-test-score.sh` — all introduced by Phase 4 non-audio. If they are missing, stop and ask the user to merge Phase 4 non-audio first.

**Namespace:** The Kotlin module's namespace `io.github.kiichiio.sheetmusic.audio` is a placeholder using the project owner's GitHub handle. Confirm with the user before Task 5 if they prefer a different group ID.

---

## Phase 0: Worktree + prerequisite check

### Task 0: Confirm prerequisites and create worktree

**Files:**
- Create: `.claude/worktrees/android-audio-backend/` (via `git worktree add`)

- [ ] **Step 1: Confirm Phase 4 non-audio is merged**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music log --oneline main | head -5
ls /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicAndroidJNI/
```

Expected: commit log shows a "Merge feature/android-compose-example" entry; directory listing includes `HandleTable.swift`, `JNISymbols.swift`, `DrawProgramEncoder.swift`. If either is missing, STOP and ask the user to merge Phase 4 non-audio.

- [ ] **Step 2: Create worktree**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music worktree add -b feature/android-audio-backend .claude/worktrees/android-audio-backend main
```

Expected: New worktree created at `.claude/worktrees/android-audio-backend` on branch `feature/android-audio-backend` based on local `main` HEAD (memory `feedback_worktree_layout`).

- [ ] **Step 3: Sanity-build the worktree**

```bash
swift build
```

(All subsequent commands run from `.claude/worktrees/android-audio-backend/` unless otherwise noted.)

Expected: clean build, no warnings.

- [ ] **Step 4: Commit nothing — Phase 0 sets up only**

(No git commit; the worktree is empty of new work.)

---

## Phase 1: Maven artifact vetting

### Task 1: Vet fluidsynth-android Maven artifact

**Files:**
- Create: `docs/superpowers/notes/2026-05-19-fluidsynth-android-vetting.md`

- [ ] **Step 1: Search Maven Central / JitPack for `fluidsynth-android` artifact**

WebFetch / WebSearch the candidates:
- `dev.atsushieno:fluidsynth-android` on Maven Central
- `dev.atsushieno:fluidsynth-fluidlite-android` as fallback
- GitHub repo `atsushieno/fluidsynth-android` for current status

For each, record:
- Latest published version + date
- Last commit / last release date on the source repo
- Open critical issues
- ABIs included (look in the `.aar` for `jni/<abi>/libfluidsynth.so`)
- FluidSynth upstream version it wraps

- [ ] **Step 2: Verify required API symbols are reachable from Kotlin**

The Kotlin engine needs the following FluidSynth APIs (either as native methods on the wrapper class or as raw NDK calls):
- `new_fluid_synth` / `delete_fluid_synth` / `fluid_synth_sfload` / `fluid_synth_program_select`
- `fluid_synth_noteon` / `fluid_synth_noteoff` / `fluid_synth_all_notes_off`
- `fluid_synth_set_gain` / `fluid_synth_cc`
- `fluid_synth_handle_midi_event`
- `fluid_synth_write_float`
- `new_fluid_player` / `delete_fluid_player` / `fluid_player_add_mem`
- `fluid_player_play` / `fluid_player_stop` / `fluid_player_join` / `fluid_player_seek`
- `fluid_player_get_current_tick`
- `fluid_player_set_playback_callback`

Open the candidate artifact's API documentation or download the `.aar` and grep its classes for these symbols.

- [ ] **Step 3: Write vetting notes**

Create `docs/superpowers/notes/2026-05-19-fluidsynth-android-vetting.md` with:
- Chosen Maven coordinate + version
- License confirmation (LGPL-2.1 dynamic-link OK)
- ABI matrix (arm64-v8a / x86_64 minimum; armv7 nice-to-have)
- Symbol coverage table (each API above: AVAILABLE / NOT AVAILABLE / DIFFERENT SIGNATURE)
- Decision: continue with per-staff `fluid_synth_t` architecture, OR pivot to single-`fluid_synth_t` + channel-per-staff (per spec "Alternative architectures considered")

- [ ] **Step 4: Commit vetting notes**

```bash
git add docs/superpowers/notes/2026-05-19-fluidsynth-android-vetting.md
git commit -m "docs(android): vet fluidsynth-android Maven artifact

Records the chosen artifact (group:name:version), license assessment,
ABI coverage, and FluidSynth API symbol availability. Confirms
per-staff fluid_synth_t architecture is viable, or documents the
pivot decision if not."
```

- [ ] **Step 5: STOP if pivot needed**

If Step 3 chose to pivot to single-`fluid_synth_t` + channel-per-staff, STOP and ask the user to revise the spec before proceeding. Otherwise, continue to Task 2.

---

## Phase 2: Swift bridge — Package.swift and skeleton

### Task 2: Add SheetMusicAudioCore dependency to SheetMusicAndroidJNI

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Read current Package.swift to locate the SheetMusicAndroidJNI target**

```bash
grep -n "SheetMusicAndroidJNI" Package.swift
```

Expected: a `.target(name: "SheetMusicAndroidJNI", ...)` block introduced by Phase 4 non-audio. Note its current `dependencies` array.

- [ ] **Step 2: Add `"SheetMusicAudioCore"` to the dependencies**

Edit `Package.swift` to add `"SheetMusicAudioCore"` to the dependencies array of the `SheetMusicAndroidJNI` target. Before:

```swift
.target(
    name: "SheetMusicAndroidJNI",
    dependencies: ["SheetMusicCore", "SheetMusicMSCX",
                   "SheetMusicMusicXML", "SheetMusicLayout"],
    path: "Sources/SheetMusicAndroidJNI"
)
```

After:

```swift
.target(
    name: "SheetMusicAndroidJNI",
    dependencies: ["SheetMusicCore", "SheetMusicMIDI",
                   "SheetMusicMSCX", "SheetMusicMusicXML",
                   "SheetMusicLayout", "SheetMusicAudioCore"],
    path: "Sources/SheetMusicAndroidJNI"
)
```

(`SheetMusicMIDI` is also added because `AudioMidiBridge` will use `MidiRenderer` / `MidiWriter`.)

- [ ] **Step 3: Verify both Apple and Android resolutions still work**

```bash
swift package describe > /tmp/describe-apple.txt
SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe > /tmp/describe-android.txt
diff /tmp/describe-apple.txt /tmp/describe-android.txt | head -40
```

Expected: both invocations succeed. Diff shows `SheetMusicAndroidJNI` present in android-only output (per CLAUDE.md recurring pitfall).

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "build(android-jni): add SheetMusicAudioCore + MIDI deps

Phase 4 audio's AudioMidiBridge.swift needs MidiRenderer, MidiWriter,
and PlaybackTimeline. The AudioCore target is Foundation-only and
already builds for Android."
```

---

### Task 3: Create AudioMidiBridge.swift skeleton

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`

- [ ] **Step 1: Create skeleton file**

```swift
#if os(Android)
    import CJNI
    import Foundation
    import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicMIDI

    // Audio JNI bridge entry points. Each @_cdecl below is callable from
    // the Kotlin class `io.github.kiichiio.sheetmusic.audio.jni.SheetMusicAudioJNI`
    // after `System.loadLibrary("SheetMusicJNI")`.
    //
    // Score handles are resolved against the existing `scoreTable` in
    // `JNISymbols.swift` (Phase 4 non-audio).

    // Audio entry points appended below per Task N.
#endif
```

- [ ] **Step 2: Verify the file compiles**

```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28
```

Expected: clean build. (No new symbols yet — just `#if os(Android)` shell.)

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift
git commit -m "feat(android-jni): scaffold AudioMidiBridge for Phase 4 audio"
```

---

### Task 4: Expose `scoreTable` for audio bridge

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/JNISymbols.swift`

The Phase 4 worktree's `scoreTable` is `private`. The audio bridge needs to look up scores by handle. Promote it to `internal` (within the SheetMusicAndroidJNI module) so `AudioMidiBridge.swift` can read it.

- [ ] **Step 1: Read current `scoreTable` declaration**

```bash
grep -n "scoreTable" Sources/SheetMusicAndroidJNI/JNISymbols.swift
```

Expected: `private let scoreTable = HandleTable<Score>()`.

- [ ] **Step 2: Drop the `private` keyword (default access = internal)**

Edit `Sources/SheetMusicAndroidJNI/JNISymbols.swift` to change:

```swift
private let scoreTable = HandleTable<Score>()
```

to:

```swift
let scoreTable = HandleTable<Score>()
```

- [ ] **Step 3: Build to confirm no breakage**

```bash
swift build
SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28
```

Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/JNISymbols.swift
git commit -m "refactor(android-jni): expose scoreTable to module-internal callers

AudioMidiBridge.swift needs handle-to-Score lookup."
```

---

## Phase 3: Binary codecs (Swift side, TDD)

These tasks define the on-the-wire format used by every audio bridge function. Swift writes; Kotlin reads. Both sides ship round-trip tests against committed golden binaries (Phase 4).

Conventions:
- Little-endian everywhere
- `u16 version` as first 2 bytes of every variable-length blob
- Length-prefixed arrays: `u16 version + i32 count + entries…`

### Task 5: BinaryWriter / BinaryReader helpers

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Audio/BinaryWriter.swift`
- Create: `Sources/SheetMusicAndroidJNI/Audio/BinaryReader.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/Audio/BinaryRoundTripTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import Foundation
import Testing
@testable import SheetMusicAndroidJNI

@Suite("BinaryWriter / BinaryReader round trip")
struct BinaryRoundTripTests {
    @Test func writesAndReadsLittleEndianIntegers() throws {
        var w = BinaryWriter()
        w.writeU16(0xABCD)
        w.writeI32(-1)
        w.writeI64(0x0102030405060708)
        var r = BinaryReader(data: w.data)
        #expect(try r.readU16() == 0xABCD)
        #expect(try r.readI32() == -1)
        #expect(try r.readI64() == 0x0102030405060708)
    }
}
```

- [ ] **Step 2: Run test (expect FAIL — symbols missing)**

```bash
swift test --filter BinaryRoundTripTests
```

Expected: compile error / no such type.

- [ ] **Step 3: Implement BinaryWriter**

```swift
// Sources/SheetMusicAndroidJNI/Audio/BinaryWriter.swift
import Foundation

struct BinaryWriter {
    private(set) var data = Data()

    mutating func writeU8(_ v: UInt8) { data.append(v) }
    mutating func writeU16(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
    }
    mutating func writeI32(_ v: Int32) {
        for i in 0..<4 { data.append(UInt8(truncatingIfNeeded: v >> (i * 8))) }
    }
    mutating func writeI64(_ v: Int64) {
        for i in 0..<8 { data.append(UInt8(truncatingIfNeeded: v >> (i * 8))) }
    }
    mutating func append(_ other: Data) { data.append(other) }
}
```

- [ ] **Step 4: Implement BinaryReader**

```swift
// Sources/SheetMusicAndroidJNI/Audio/BinaryReader.swift
import Foundation

struct BinaryReader {
    let data: Data
    private var offset = 0

    init(data: Data) { self.data = data }

    enum BinaryReaderError: Error { case underflow }

    mutating func readU8() throws -> UInt8 {
        guard offset < data.count else { throw BinaryReaderError.underflow }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
    mutating func readU16() throws -> UInt16 {
        let lo = UInt16(try readU8())
        let hi = UInt16(try readU8())
        return lo | (hi << 8)
    }
    mutating func readI32() throws -> Int32 {
        var v: Int32 = 0
        for i in 0..<4 { v |= Int32(try readU8()) << (i * 8) }
        return v
    }
    mutating func readI64() throws -> Int64 {
        var v: Int64 = 0
        for i in 0..<8 { v |= Int64(try readU8()) << (i * 8) }
        return v
    }
    var remaining: Int { data.count - offset }
}
```

- [ ] **Step 5: Run test (expect PASS)**

```bash
swift test --filter BinaryRoundTripTests
```

Expected: 1 test passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/Audio/ Tests/SheetMusicTests/AndroidJNI/Audio/
git commit -m "feat(android-jni): little-endian BinaryWriter / BinaryReader"
```

---

### Task 6: ScoreCursor codec

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Audio/ScoreCursorCodec.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/Audio/ScoreCursorCodecTests.swift`

`ScoreCursor` is the Foundation type in `SheetMusicCore`. Inspect its current shape with `grep -n "struct ScoreCursor" Sources/SheetMusicCore/Score/*.swift` and note its fields (`staff: StaffAddress`, `measureIndex: Int`, `voiceIndex: Int`, `elementIndex: Int`, `noteIndexInChord: Int?`).

`StaffAddress` is an enum with two cases (`part(...)` / `flat(...)`); inspect via `grep -rn "enum StaffAddress" Sources/SheetMusicCore/`. The codec must encode the discriminator + payload — read the existing enum and mirror it.

- [ ] **Step 1: Write failing round-trip test**

```swift
import Foundation
import Testing
import SheetMusicCore
@testable import SheetMusicAndroidJNI

@Suite("ScoreCursorCodec round trip")
struct ScoreCursorCodecTests {
    @Test func encodesAndDecodesPartCursor() throws {
        let cursor = ScoreCursor(
            staff: .part(partIndex: 0, staffOffset: 1),
            measureIndex: 4, voiceIndex: 0, elementIndex: 2,
            noteIndexInChord: 1,
        )
        let bytes = ScoreCursorCodec.encode(cursor)
        var r = BinaryReader(data: bytes)
        let decoded = try ScoreCursorCodec.decode(&r)
        #expect(decoded == cursor)
    }

    @Test func encodesAndDecodesRestCursor() throws {
        let cursor = ScoreCursor(
            staff: .part(partIndex: 2, staffOffset: 0),
            measureIndex: 0, voiceIndex: 1, elementIndex: 0,
            noteIndexInChord: nil,
        )
        let bytes = ScoreCursorCodec.encode(cursor)
        var r = BinaryReader(data: bytes)
        #expect(try ScoreCursorCodec.decode(&r) == cursor)
    }
}
```

- [ ] **Step 2: Run test (expect FAIL)**

```bash
swift test --filter ScoreCursorCodecTests
```

- [ ] **Step 3: Implement codec**

(Adjust the StaffAddress switch to match the actual enum cases from the codebase.)

```swift
// Sources/SheetMusicAndroidJNI/Audio/ScoreCursorCodec.swift
import Foundation
import SheetMusicCore

enum ScoreCursorCodec {
    static let formatVersion: UInt16 = 1

    static func encode(_ cursor: ScoreCursor) -> Data {
        var w = BinaryWriter()
        w.writeU16(formatVersion)
        encode(cursor, into: &w)
        return w.data
    }

    static func encode(_ cursor: ScoreCursor, into w: inout BinaryWriter) {
        // Adjust the discriminator + payloads to actual StaffAddress cases.
        switch cursor.staff {
        case .part(let partIndex, let staffOffset):
            w.writeI32(0)
            w.writeI64(Int64(partIndex))
            w.writeI64(Int64(staffOffset))
        }
        w.writeI32(Int32(cursor.measureIndex))
        w.writeI32(Int32(cursor.voiceIndex))
        w.writeI32(Int32(cursor.elementIndex))
        w.writeI32(Int32(cursor.noteIndexInChord ?? -1))
    }

    static func decode(_ r: inout BinaryReader) throws -> ScoreCursor {
        let version = try r.readU16()
        guard version == formatVersion else {
            throw BinaryReader.BinaryReaderError.underflow
        }
        return try decodePayload(&r)
    }

    static func decodePayload(_ r: inout BinaryReader) throws -> ScoreCursor {
        let discriminator = try r.readI32()
        let staff: StaffAddress
        switch discriminator {
        case 0:
            let partIndex = Int(try r.readI64())
            let staffOffset = Int(try r.readI64())
            staff = .part(partIndex: partIndex, staffOffset: staffOffset)
        default:
            throw BinaryReader.BinaryReaderError.underflow
        }
        let measureIndex = Int(try r.readI32())
        let voiceIndex = Int(try r.readI32())
        let elementIndex = Int(try r.readI32())
        let n = Int(try r.readI32())
        return ScoreCursor(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
            noteIndexInChord: n < 0 ? nil : n,
        )
    }
}
```

- [ ] **Step 4: Run test (expect PASS)**

```bash
swift test --filter ScoreCursorCodecTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/Audio/ScoreCursorCodec.swift \
        Tests/SheetMusicTests/AndroidJNI/Audio/ScoreCursorCodecTests.swift
git commit -m "feat(android-jni): ScoreCursor binary codec for audio bridge"
```

---

### Task 7: NoteID / ScoreItemID codecs

These share `ScoreCursor`'s payload structure plus chord-note disambiguation. Reuse `ScoreCursorCodec.encode/decodePayload`.

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Audio/NoteIDCodec.swift`
- Create: `Sources/SheetMusicAndroidJNI/Audio/ScoreItemIDCodec.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/Audio/NoteIDCodecTests.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/Audio/ScoreItemIDCodecTests.swift`

- [ ] **Step 1: Inspect the actual `NoteID` and `ScoreItemID` declarations**

```bash
grep -rn "struct NoteID" Sources/SheetMusicCore/
grep -rn "enum ScoreItemID\|struct ScoreItemID" Sources/SheetMusicCore/
```

Note: `NoteID` and `ScoreItemID` may already wrap a `ScoreCursor`. If so, codec is trivial.

- [ ] **Step 2: Write failing tests (mirror `ScoreCursorCodecTests`'s round-trip pattern; adjust types)**

(Replicate ScoreCursor's two test methods, substituting NoteID and ScoreItemID values.)

- [ ] **Step 3: Implement codecs that delegate to ScoreCursorCodec for the cursor portion**

```swift
// Sources/SheetMusicAndroidJNI/Audio/NoteIDCodec.swift
import Foundation
import SheetMusicCore

enum NoteIDCodec {
    static let formatVersion: UInt16 = 1

    static func encode(_ id: NoteID) -> Data {
        var w = BinaryWriter()
        w.writeU16(formatVersion)
        // Encode the underlying ScoreCursor payload + an i32 noteIndex
        // (mirror NoteID's actual fields — check grep output from Step 1
        // and adjust the field projections below.)
        ScoreCursorCodec.encode(id.cursor, into: &w)
        return w.data
    }

    static func decode(_ r: inout BinaryReader) throws -> NoteID {
        guard try r.readU16() == formatVersion else {
            throw BinaryReader.BinaryReaderError.underflow
        }
        let cursor = try ScoreCursorCodec.decodePayload(&r)
        return NoteID(cursor: cursor)
    }
}
```

`ScoreItemIDCodec` follows the same pattern. If either type has additional fields beyond the cursor, extend the encode/decode body in the same shape.

- [ ] **Step 4: Run tests (expect PASS)**

```bash
swift test --filter NoteIDCodecTests
swift test --filter ScoreItemIDCodecTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/Audio/NoteIDCodec.swift \
        Sources/SheetMusicAndroidJNI/Audio/ScoreItemIDCodec.swift \
        Tests/SheetMusicTests/AndroidJNI/Audio/NoteIDCodecTests.swift \
        Tests/SheetMusicTests/AndroidJNI/Audio/ScoreItemIDCodecTests.swift
git commit -m "feat(android-jni): NoteID / ScoreItemID binary codecs"
```

---

### Task 8: MetronomeBeat codec

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Audio/MetronomeBeatCodec.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/Audio/MetronomeBeatCodecTests.swift`

`MetronomeBeat` is in `SheetMusicAudioCore`. Inspect via `grep -n "struct MetronomeBeat" Sources/SheetMusicAudioCore/MetronomeBeat.swift`.

- [ ] **Step 1: Write failing round-trip test**

```swift
import Foundation
import Testing
import SheetMusicAudioCore
@testable import SheetMusicAndroidJNI

@Suite("MetronomeBeatCodec round trip")
struct MetronomeBeatCodecTests {
    @Test func encodesArrayOfBeats() throws {
        let beats = [
            MetronomeBeat(tick: 0, kind: .downbeat),
            MetronomeBeat(tick: 480, kind: .upbeat),
            MetronomeBeat(tick: 960, kind: .subdivision),
        ]
        let bytes = MetronomeBeatCodec.encodeArray(beats)
        let decoded = try MetronomeBeatCodec.decodeArray(Data(bytes))
        #expect(decoded == beats)
    }
}
```

(If `MetronomeBeat.Kind` differs from `downbeat`/`upbeat`/`subdivision`, use the actual cases.)

- [ ] **Step 2: Run (expect FAIL)**

- [ ] **Step 3: Implement**

```swift
// Sources/SheetMusicAndroidJNI/Audio/MetronomeBeatCodec.swift
import Foundation
import SheetMusicAudioCore

enum MetronomeBeatCodec {
    static let formatVersion: UInt16 = 1

    static func encodeArray(_ beats: [MetronomeBeat]) -> Data {
        var w = BinaryWriter()
        w.writeU16(formatVersion)
        w.writeI32(Int32(beats.count))
        for b in beats {
            w.writeI64(Int64(b.tick))
            // Map Kind to a stable Int32 (0=downbeat / 1=upbeat / 2=subdivision).
            w.writeI32(kindToInt32(b.kind))
            w.writeI32(0)  // reserved
        }
        return w.data
    }

    static func decodeArray(_ data: Data) throws -> [MetronomeBeat] {
        var r = BinaryReader(data: data)
        guard try r.readU16() == formatVersion else {
            throw BinaryReader.BinaryReaderError.underflow
        }
        let count = Int(try r.readI32())
        var out: [MetronomeBeat] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let tick = Int(try r.readI64())
            let kindInt = try r.readI32()
            _ = try r.readI32()
            out.append(MetronomeBeat(tick: tick, kind: int32ToKind(kindInt)))
        }
        return out
    }

    private static func kindToInt32(_ k: MetronomeBeat.Kind) -> Int32 {
        switch k {
        case .downbeat: return 0
        case .upbeat: return 1
        case .subdivision: return 2
        }
    }

    private static func int32ToKind(_ v: Int32) -> MetronomeBeat.Kind {
        switch v {
        case 0: return .downbeat
        case 1: return .upbeat
        default: return .subdivision
        }
    }
}
```

- [ ] **Step 4: Run test (expect PASS)**

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/Audio/MetronomeBeatCodec.swift \
        Tests/SheetMusicTests/AndroidJNI/Audio/MetronomeBeatCodecTests.swift
git commit -m "feat(android-jni): MetronomeBeat array codec"
```

---

### Task 9: Frame codec

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Audio/FrameCodec.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/Audio/FrameCodecTests.swift`

Frame = `(tick, timeSecondsMicros, cursor)`. `timeSecondsMicros` = `timeSeconds * 1e6` rounded to `Int64` so the Kotlin side divides by `1e6` to recover seconds.

- [ ] **Step 1: Write failing test**

```swift
import Foundation
import Testing
import SheetMusicAudioCore
import SheetMusicCore
@testable import SheetMusicAndroidJNI

@Suite("FrameCodec round trip")
struct FrameCodecTests {
    @Test func encodesAndDecodesFrame() throws {
        let cursor = ScoreCursor(
            staff: .part(partIndex: 0, staffOffset: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
            noteIndexInChord: 0,
        )
        let frame = PlaybackTimeline.Frame(
            tick: 480, timeSeconds: 1.5, cursor: cursor,
        )
        let bytes = FrameCodec.encode(frame)
        let decoded = try FrameCodec.decode(Data(bytes))
        #expect(decoded?.tick == frame.tick)
        #expect(abs((decoded?.timeSeconds ?? 0) - frame.timeSeconds) < 1e-6)
        #expect(decoded?.cursor == frame.cursor)
    }

    @Test func emptyDataDecodesToNil() throws {
        #expect(try FrameCodec.decode(Data()) == nil)
    }
}
```

- [ ] **Step 2: Run (expect FAIL)**

- [ ] **Step 3: Implement**

```swift
// Sources/SheetMusicAndroidJNI/Audio/FrameCodec.swift
import Foundation
import SheetMusicAudioCore
import SheetMusicCore

enum FrameCodec {
    static let formatVersion: UInt16 = 1

    static func encode(_ frame: PlaybackTimeline.Frame) -> Data {
        var w = BinaryWriter()
        w.writeU16(formatVersion)
        w.writeI64(Int64(frame.tick))
        let micros = Int64((frame.timeSeconds * 1_000_000).rounded())
        w.writeI64(micros)
        ScoreCursorCodec.encode(frame.cursor, into: &w)
        return w.data
    }

    static func decode(_ data: Data) throws -> PlaybackTimeline.Frame? {
        guard !data.isEmpty else { return nil }
        var r = BinaryReader(data: data)
        guard try r.readU16() == formatVersion else {
            throw BinaryReader.BinaryReaderError.underflow
        }
        let tick = Int(try r.readI64())
        let micros = try r.readI64()
        let cursor = try ScoreCursorCodec.decodePayload(&r)
        return PlaybackTimeline.Frame(
            tick: tick,
            timeSeconds: TimeInterval(micros) / 1_000_000,
            cursor: cursor,
        )
    }
}
```

(`ScoreCursorCodec.encode(_:into:)` writes the discriminator + payload but skips its own version byte when called this way — `FrameCodec`'s outer version covers the whole blob.)

- [ ] **Step 4: Run test (expect PASS)**

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/Audio/FrameCodec.swift \
        Tests/SheetMusicTests/AndroidJNI/Audio/FrameCodecTests.swift
git commit -m "feat(android-jni): Frame codec (tick, timeSeconds, cursor)"
```

---

### Task 10: StaffParams codec

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Audio/StaffParamsCodec.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/Audio/StaffParamsCodecTests.swift`

```swift
struct StaffParams: Equatable {
    let staffIndex: Int
    let bankLSB: UInt8
    let program: UInt8
    let isDrums: Bool
    let partAddressHash: Int64
}
```

- [ ] **Step 1: Write failing test** (length-prefixed array of 3 entries; assert byte-for-byte round trip).

- [ ] **Step 2: Implement**

```swift
// Sources/SheetMusicAndroidJNI/Audio/StaffParamsCodec.swift
import Foundation

struct StaffParams: Equatable {
    let staffIndex: Int
    let bankLSB: UInt8
    let program: UInt8
    let isDrums: Bool
    let partAddressHash: Int64
}

enum StaffParamsCodec {
    static let formatVersion: UInt16 = 1

    static func encodeArray(_ entries: [StaffParams]) -> Data {
        var w = BinaryWriter()
        w.writeU16(formatVersion)
        w.writeI32(Int32(entries.count))
        for e in entries {
            w.writeI32(Int32(e.staffIndex))
            w.writeU8(e.bankLSB)
            w.writeU8(e.program)
            w.writeU8(e.isDrums ? 1 : 0)
            w.writeU8(0)
            w.writeI64(e.partAddressHash)
        }
        return w.data
    }

    static func decodeArray(_ data: Data) throws -> [StaffParams] {
        var r = BinaryReader(data: data)
        guard try r.readU16() == formatVersion else {
            throw BinaryReader.BinaryReaderError.underflow
        }
        let count = Int(try r.readI32())
        var out: [StaffParams] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let staffIndex = Int(try r.readI32())
            let bankLSB = try r.readU8()
            let program = try r.readU8()
            let isDrums = try r.readU8() != 0
            _ = try r.readU8()
            let hash = try r.readI64()
            out.append(StaffParams(
                staffIndex: staffIndex, bankLSB: bankLSB,
                program: program, isDrums: isDrums,
                partAddressHash: hash,
            ))
        }
        return out
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/Audio/StaffParamsCodec.swift \
        Tests/SheetMusicTests/AndroidJNI/Audio/StaffParamsCodecTests.swift
git commit -m "feat(android-jni): StaffParams codec"
```

---

## Phase 4: Swift bridge — @_cdecl functions (TDD)

Each task implements one `@_cdecl` plus a test that calls the function directly (bypassing JNI) to verify the underlying logic. The `@_cdecl` wrapper is thin glue — test the inner helper.

### Task 11: SMF channel-relabel + `nativeRenderMidi`

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/AudioMidiBridgeTests.swift`

- [ ] **Step 1: Write failing test for channel-relabel helper**

```swift
import Foundation
import Testing
import SheetMusicMIDI
@testable import SheetMusicAndroidJNI

@Suite("AudioMidiBridge — render")
struct AudioMidiBridgeRenderTests {
    @Test func relabelChannelsToTrackIndex() {
        var midi = MidiFile(division: 480, tracks: [
            MidiTrack(events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, note: 60, velocity: 96)),
            ]),
            MidiTrack(events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, note: 62, velocity: 96)),
            ]),
        ])
        AudioMidiBridge.relabelChannelsToTrackIndex(&midi)
        if case .noteOn(let ch, _, _) = midi.tracks[0].events[0].event {
            #expect(ch == 0)
        } else { Issue.record("expected noteOn") }
        if case .noteOn(let ch, _, _) = midi.tracks[1].events[0].event {
            #expect(ch == 1)
        } else { Issue.record("expected noteOn") }
    }
}
```

- [ ] **Step 2: Run (expect FAIL — function missing)**

- [ ] **Step 3: Implement helper inside AudioMidiBridge.swift**

Add to `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`:

```swift
enum AudioMidiBridge {
    /// Rewrite every channel-bearing event's channel field to its track index
    /// (modulo 16). Required because fluid_player does not surface track origin
    /// in its playback callback; we recover staff index from event.channel.
    static func relabelChannelsToTrackIndex(_ midi: inout MidiFile) {
        for trackIdx in midi.tracks.indices {
            let newChannel = UInt8(trackIdx & 0x0F)
            var rewritten: [TimedMidiEvent] = []
            rewritten.reserveCapacity(midi.tracks[trackIdx].events.count)
            for evt in midi.tracks[trackIdx].events {
                let newEvent: MidiEvent
                switch evt.event {
                case .noteOn(_, let n, let v):
                    newEvent = .noteOn(channel: newChannel, note: n, velocity: v)
                case .noteOff(_, let n, let v):
                    newEvent = .noteOff(channel: newChannel, note: n, velocity: v)
                case .controlChange(_, let c, let v):
                    newEvent = .controlChange(channel: newChannel, controller: c, value: v)
                case .programChange(_, let p):
                    newEvent = .programChange(channel: newChannel, program: p)
                case .pitchBend(_, let v):
                    newEvent = .pitchBend(channel: newChannel, value: v)
                default:
                    newEvent = evt.event
                }
                rewritten.append(TimedMidiEvent(tick: evt.tick, event: newEvent))
            }
            midi.tracks[trackIdx] = MidiTrack(events: rewritten)
        }
    }
}
```

(Adapt the switch arms to match the actual `MidiEvent` enum cases in `Sources/SheetMusicMIDI/Model/MidiEvent.swift`.)

- [ ] **Step 4: Run test (expect PASS)**

- [ ] **Step 5: Add `renderMidi(scoreHandle:)` helper + integration test**

Append to AudioMidiBridge.swift:

```swift
extension AudioMidiBridge {
    static func renderMidi(score: Score) throws -> Data {
        var midi = try MidiRenderer.render(score: score)
        relabelChannelsToTrackIndex(&midi)
        return try MidiWriter.write(midi)
    }
}
```

Test (append to AudioMidiBridgeRenderTests):

```swift
@Test func renderMidiReturnsValidSMF() throws {
    let score = try MSCXParser.parse(/* small fixture mscx Data */)
    let bytes = try AudioMidiBridge.renderMidi(score: score)
    let parsed = try MidiParser.parse(bytes)
    #expect(parsed.tracks.count == score.allStaves.count + 1) // + tempo track
}
```

(Use any existing small mscx fixture from `Tests/SheetMusicTests/Resources/`.)

- [ ] **Step 6: Run test (expect PASS)**

- [ ] **Step 7: Add the @_cdecl wrapper**

Append to AudioMidiBridge.swift inside the `#if os(Android)` block:

```swift
@_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeRenderMidi")
// swiftlint:disable:next identifier_name
public func Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeRenderMidi(
    _ envPtr: UnsafeMutablePointer<JNIEnv?>,
    _ clazz: jclass,
    _ scoreHandle: jlong,
) -> jbyteArray? {
    guard let env = envPtr.pointee,
          let score = scoreTable.value(for: scoreHandle)
    else { return envPtr.pointee?.NewByteArray(envPtr, 0) }
    guard let bytes = try? AudioMidiBridge.renderMidi(score: score) else {
        return env.NewByteArray(envPtr, 0)
    }
    let array = env.NewByteArray(envPtr, jsize(bytes.count))
    bytes.withUnsafeBytes { rawBuf in
        let typed = rawBuf.bindMemory(to: jbyte.self)
        env.pointee.SetByteArrayRegion(
            envPtr, array, 0, jsize(bytes.count), typed.baseAddress,
        )
    }
    return array
}
```

- [ ] **Step 8: Cross-compile to verify Android target**

```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28
```

Expected: clean build.

- [ ] **Step 9: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift \
        Tests/SheetMusicTests/AndroidJNI/AudioMidiBridgeTests.swift
git commit -m "feat(android-jni): nativeRenderMidi with channel-relabel preprocess"
```

---

### Task 12: `nativeTimelineSummary`

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/AudioMidiBridgeTests.swift`

- [ ] **Step 1: Write failing test**

```swift
@Test func timelineSummaryMatchesPlaybackTimeline() throws {
    let score = try MSCXParser.parse(/* fixture */)
    let summary = AudioMidiBridge.timelineSummary(score: score)
    let timeline = PlaybackTimeline(score: score)
    #expect(summary.totalTicks == Int64(timeline.totalTicks))
    #expect(abs(Double(summary.totalSecondsMicros) / 1e6 - timeline.totalSeconds) < 0.001)
    #expect(summary.division == Int64(timeline.division))
}
```

- [ ] **Step 2: Implement helper**

```swift
extension AudioMidiBridge {
    struct TimelineSummary: Equatable {
        let totalTicks: Int64
        let totalSecondsMicros: Int64
        let division: Int64
    }

    static func timelineSummary(score: Score) -> TimelineSummary {
        let t = PlaybackTimeline(score: score)
        return TimelineSummary(
            totalTicks: Int64(t.totalTicks),
            totalSecondsMicros: Int64((t.totalSeconds * 1_000_000).rounded()),
            division: Int64(t.division),
        )
    }
}
```

- [ ] **Step 3: Add @_cdecl wrapper returning jlongArray of 3 entries**

```swift
@_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeTimelineSummary")
// swiftlint:disable:next identifier_name
public func Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeTimelineSummary(
    _ envPtr: UnsafeMutablePointer<JNIEnv?>,
    _ clazz: jclass,
    _ scoreHandle: jlong,
) -> jlongArray? {
    guard let env = envPtr.pointee,
          let score = scoreTable.value(for: scoreHandle)
    else { return envPtr.pointee?.NewLongArray(envPtr, 0) }
    let s = AudioMidiBridge.timelineSummary(score: score)
    let array = env.NewLongArray(envPtr, 3)
    var values: [jlong] = [s.totalTicks, s.totalSecondsMicros, s.division]
    values.withUnsafeMutableBufferPointer { buf in
        env.pointee.SetLongArrayRegion(envPtr, array, 0, 3, buf.baseAddress)
    }
    return array
}
```

- [ ] **Step 4: Run test + cross-compile (expect PASS)**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(android-jni): nativeTimelineSummary"
```

---

### Task 13: `nativeFrameAtTick` + `nativeFrameForCursor`

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/AudioMidiBridgeTests.swift`

- [ ] **Step 1: Test — `frameAtTick` and `frameForCursor` return encoded Frame bytes**

```swift
@Test func frameAtTickEncodesFromPlaybackTimeline() throws {
    let score = try MSCXParser.parse(/* fixture */)
    let timeline = PlaybackTimeline(score: score)
    guard let firstFrame = timeline.frames.first else {
        Issue.record("no frames"); return
    }
    let bytes = AudioMidiBridge.frameAtTick(score: score, tick: Int64(firstFrame.tick))
    let decoded = try FrameCodec.decode(bytes)
    #expect(decoded?.tick == firstFrame.tick)
}

@Test func frameForCursorEncodesFromPlaybackTimeline() throws {
    let score = try MSCXParser.parse(/* fixture */)
    let timeline = PlaybackTimeline(score: score)
    guard let firstFrame = timeline.frames.first else { return }
    let bytes = AudioMidiBridge.frameForCursor(
        score: score, cursor: firstFrame.cursor,
    )
    let decoded = try FrameCodec.decode(bytes)
    #expect(decoded?.tick == firstFrame.tick)
}
```

- [ ] **Step 2: Implement helpers + @_cdecl wrappers**

```swift
extension AudioMidiBridge {
    static func frameAtTick(score: Score, tick: Int64) -> Data {
        let timeline = PlaybackTimeline(score: score)
        guard let frame = timeline.frame(atTick: Int(tick)) else { return Data() }
        return FrameCodec.encode(frame)
    }

    static func frameForCursor(score: Score, cursor: ScoreCursor) -> Data {
        let timeline = PlaybackTimeline(score: score)
        guard let frame = timeline.frame(forCursor: cursor) else { return Data() }
        return FrameCodec.encode(frame)
    }
}

@_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeFrameAtTick")
// swiftlint:disable:next identifier_name
public func Java_..._nativeFrameAtTick(
    _ envPtr: UnsafeMutablePointer<JNIEnv?>, _ clazz: jclass,
    _ scoreHandle: jlong, _ tick: jlong,
) -> jbyteArray? {
    guard let env = envPtr.pointee,
          let score = scoreTable.value(for: scoreHandle)
    else { return envPtr.pointee?.NewByteArray(envPtr, 0) }
    let bytes = AudioMidiBridge.frameAtTick(score: score, tick: tick)
    return makeJByteArray(env: envPtr, bytes: bytes)
}

@_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeFrameForCursor")
// swiftlint:disable:next identifier_name
public func Java_..._nativeFrameForCursor(
    _ envPtr: UnsafeMutablePointer<JNIEnv?>, _ clazz: jclass,
    _ scoreHandle: jlong, _ cursorBytes: jbyteArray,
) -> jbyteArray? {
    guard let env = envPtr.pointee,
          let score = scoreTable.value(for: scoreHandle)
    else { return envPtr.pointee?.NewByteArray(envPtr, 0) }
    let data = readJByteArray(env: envPtr, array: cursorBytes)
    var r = BinaryReader(data: data)
    guard let cursor = try? ScoreCursorCodec.decode(&r) else {
        return env.NewByteArray(envPtr, 0)
    }
    let bytes = AudioMidiBridge.frameForCursor(score: score, cursor: cursor)
    return makeJByteArray(env: envPtr, bytes: bytes)
}
```

Also add the JNI helpers `makeJByteArray` and `readJByteArray` to AudioMidiBridge.swift (one-time, shared by remaining tasks):

```swift
#if os(Android)
fileprivate func makeJByteArray(
    env: UnsafeMutablePointer<JNIEnv?>, bytes: Data,
) -> jbyteArray? {
    guard let envP = env.pointee else { return nil }
    let array = envP.NewByteArray(env, jsize(bytes.count))
    bytes.withUnsafeBytes { rawBuf in
        let typed = rawBuf.bindMemory(to: jbyte.self)
        envP.pointee.SetByteArrayRegion(
            env, array, 0, jsize(bytes.count), typed.baseAddress,
        )
    }
    return array
}

fileprivate func readJByteArray(
    env: UnsafeMutablePointer<JNIEnv?>, array: jbyteArray,
) -> Data {
    guard let envP = env.pointee else { return Data() }
    let len = envP.GetArrayLength(env, array)
    guard len > 0 else { return Data() }
    var buf = [UInt8](repeating: 0, count: Int(len))
    buf.withUnsafeMutableBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return }
        base.withMemoryRebound(to: jbyte.self, capacity: Int(len)) { jp in
            envP.pointee.GetByteArrayRegion(env, array, 0, len, jp)
        }
    }
    return Data(buf)
}
#endif
```

(Replace `Java_..._` placeholders with the full mangled names; ellipses are for plan readability only.)

- [ ] **Step 3: Run tests + cross-compile**

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(android-jni): nativeFrameAtTick + nativeFrameForCursor"
```

---

### Task 14: `nativeMetronomeBeats` + `nativeStaffParams`

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/AudioMidiBridgeTests.swift`

- [ ] **Step 1: Write tests**

```swift
@Test func metronomeBeatsMatchesAudioCoreHelper() throws {
    let score = try MSCXParser.parse(/* fixture */)
    let bytes = AudioMidiBridge.metronomeBeats(score: score)
    let decoded = try MetronomeBeatCodec.decodeArray(bytes)
    let expected = PlaybackTimeline.metronomeBeats(score: score)
    #expect(decoded == expected)
}

@Test func staffParamsListsAllStaves() throws {
    let score = try MSCXParser.parse(/* fixture */)
    let bytes = AudioMidiBridge.staffParams(score: score)
    let decoded = try StaffParamsCodec.decodeArray(bytes)
    #expect(decoded.count == score.allStaves.count)
}
```

- [ ] **Step 2: Implement helpers**

```swift
extension AudioMidiBridge {
    static func metronomeBeats(score: Score) -> Data {
        let beats = PlaybackTimeline.metronomeBeats(score: score)
        return MetronomeBeatCodec.encodeArray(beats)
    }

    static func staffParams(score: Score) -> Data {
        let entries = score.allStaves.enumerated().map { idx, entry -> StaffParams in
            let part = score.part(at: entry.address)
            let channel = part?.instrument.channels.first ?? InstrumentChannel()
            return StaffParams(
                staffIndex: idx,
                bankLSB: UInt8(clamping: channel.bank),
                program: UInt8(clamping: channel.program),
                isDrums: part?.instrument.useDrumset == true,
                partAddressHash: Int64(entry.address.hashValue),
            )
        }
        return StaffParamsCodec.encodeArray(entries)
    }
}
```

- [ ] **Step 3: Add @_cdecl wrappers** (same shape as Task 13)

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(android-jni): nativeMetronomeBeats + nativeStaffParams"
```

---

### Task 15: `nativePitchAndStaffOfNote` + `nativeEarliestOf`

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/AudioMidiBridgeTests.swift`

- [ ] **Step 1: Write tests**

```swift
@Test func pitchAndStaffOfNoteResolvesValidNote() throws {
    let score = try MSCXParser.parse(/* fixture */)
    // Construct a known NoteID from the fixture's first chord-note
    let nid = /* first chord NoteID derived from score */
    let packed = AudioMidiBridge.pitchAndStaffOfNote(score: score, noteId: nid)
    #expect(packed != Int64(bitPattern: 0xFFFFFFFFFFFFFFFF))
}

@Test func earliestOfReturnsLowestTickItem() throws {
    let score = try MSCXParser.parse(/* fixture */)
    let ids: [ScoreItemID] = /* two IDs whose ticks differ */
    let bytes = AudioMidiBridge.earliestOf(score: score, ids: ids)
    let decoded = try ScoreItemIDCodec.decode(Data(bytes))
    #expect(decoded != nil)
}
```

- [ ] **Step 2: Implement helpers**

```swift
extension AudioMidiBridge {
    static func pitchAndStaffOfNote(score: Score, noteId: NoteID) -> Int64 {
        guard let staff = score[noteId.cursor.staff] else { return Int64(bitPattern: 0xFFFFFFFFFFFFFFFF) }
        let flatIdx = score.allStaves.firstIndex { $0.address == noteId.cursor.staff } ?? -1
        guard flatIdx >= 0,
              noteId.cursor.measureIndex < staff.measures.count
        else { return Int64(bitPattern: 0xFFFFFFFFFFFFFFFF) }
        let m = staff.measures[noteId.cursor.measureIndex]
        guard noteId.cursor.voiceIndex < m.voices.count else { return Int64(bitPattern: 0xFFFFFFFFFFFFFFFF) }
        let v = m.voices[noteId.cursor.voiceIndex]
        guard noteId.cursor.elementIndex < v.elements.count,
              case let .chord(chord) = v.elements[noteId.cursor.elementIndex],
              let n = noteId.cursor.noteIndexInChord, n < chord.notes.count
        else { return Int64(bitPattern: 0xFFFFFFFFFFFFFFFF) }
        let pitch = UInt32(clamping: chord.notes[n].pitch)
        let staffIdx = UInt32(flatIdx)
        return Int64(bitPattern: (UInt64(pitch) << 32) | UInt64(staffIdx))
    }

    static func earliestOf(score: Score, ids: [ScoreItemID]) -> Data {
        let timeline = PlaybackTimeline(score: score)
        guard let earliest = timeline.earliest(of: ids) else { return Data() }
        return ScoreItemIDCodec.encode(earliest)
    }
}
```

- [ ] **Step 3: Add @_cdecl wrappers** (jlong return for pitchAndStaffOfNote; jbyteArray with length-prefixed ScoreItemID list input for earliestOf — also extend `ScoreItemIDCodec` with `decodeArray` if not yet present)

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(android-jni): nativePitchAndStaffOfNote + nativeEarliestOf"
```

---

## Phase 5: Golden binaries

### Task 16: Generate and commit golden binaries

**Files:**
- Create: `Tests/SheetMusicTests/Resources/Golden/Audio/frame-v1.bin`
- Create: `Tests/SheetMusicTests/Resources/Golden/Audio/cursor-v1.bin`
- Create: `Tests/SheetMusicTests/Resources/Golden/Audio/noteId-v1.bin`
- Create: `Tests/SheetMusicTests/Resources/Golden/Audio/scoreItemId-v1.bin`
- Create: `Tests/SheetMusicTests/Resources/Golden/Audio/metronomeBeat-v1.bin`
- Create: `Tests/SheetMusicTests/Resources/Golden/Audio/staffParams-v1.bin`
- Create: `Tests/SheetMusicTests/AndroidJNI/Audio/GoldenBinaryTests.swift`

- [ ] **Step 1: Write golden-generation test**

```swift
@Suite("Golden binary fixtures")
struct GoldenBinaryTests {
    private let goldenDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/Golden/Audio")

    @Test func frameGoldenMatchesCommitted() throws {
        let cursor = ScoreCursor(
            staff: .part(partIndex: 0, staffOffset: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
            noteIndexInChord: 0,
        )
        let frame = PlaybackTimeline.Frame(tick: 480, timeSeconds: 1.5, cursor: cursor)
        let encoded = FrameCodec.encode(frame)
        let committed = try Data(contentsOf: goldenDir.appendingPathComponent("frame-v1.bin"))
        #expect(encoded == committed)
    }
    // … similar test methods for cursor / noteId / scoreItemId / metronomeBeat / staffParams …
}
```

- [ ] **Step 2: Run the test once to capture the expected bytes**

The test fails initially; on first failure, write the generated bytes to disk:

```swift
@Test func generateAllGoldenBinaries() throws {
    let dir = goldenDir
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // frame-v1.bin
    let cursor = ScoreCursor(...)
    let frame = PlaybackTimeline.Frame(tick: 480, timeSeconds: 1.5, cursor: cursor)
    try FrameCodec.encode(frame).write(to: dir.appendingPathComponent("frame-v1.bin"))
    // cursor-v1.bin / noteId-v1.bin / scoreItemId-v1.bin
    try ScoreCursorCodec.encode(cursor).write(to: dir.appendingPathComponent("cursor-v1.bin"))
    let nid = NoteID(cursor: cursor)
    try NoteIDCodec.encode(nid).write(to: dir.appendingPathComponent("noteId-v1.bin"))
    let sid = ScoreItemID(cursor: cursor)
    try ScoreItemIDCodec.encode(sid).write(to: dir.appendingPathComponent("scoreItemId-v1.bin"))
    // metronomeBeat-v1.bin
    let beats = [
        MetronomeBeat(tick: 0, kind: .downbeat),
        MetronomeBeat(tick: 480, kind: .upbeat),
        MetronomeBeat(tick: 960, kind: .subdivision),
    ]
    try MetronomeBeatCodec.encodeArray(beats)
        .write(to: dir.appendingPathComponent("metronomeBeat-v1.bin"))
    // staffParams-v1.bin
    let params = [
        StaffParams(staffIndex: 0, bankLSB: 0, program: 0,
                    isDrums: false, partAddressHash: 1234),
        StaffParams(staffIndex: 1, bankLSB: 0, program: 0,
                    isDrums: true, partAddressHash: 5678),
    ]
    try StaffParamsCodec.encodeArray(params)
        .write(to: dir.appendingPathComponent("staffParams-v1.bin"))
}
```

Run this test once:

```bash
swift test --filter GoldenBinaryTests/generateAllGoldenBinaries
```

Then delete the generation method (it should not stay in CI). Keep only the round-trip assertions.

- [ ] **Step 3: Run remaining assertions**

```bash
swift test --filter GoldenBinaryTests
```

Expected: all golden round-trip tests PASS.

- [ ] **Step 4: Commit golden binaries + tests**

```bash
git add Tests/SheetMusicTests/Resources/Golden/Audio/ \
        Tests/SheetMusicTests/AndroidJNI/Audio/GoldenBinaryTests.swift
git commit -m "test(android-jni): commit golden binaries for audio codecs

Each binary is the v1 wire format for its codec. Both Swift and Kotlin
tests assert byte-for-byte equality against these files. Any
inadvertent format change fails CI loudly."
```

---

## Phase 6: Gradle module skeleton

### Task 17: Top-level `Android/` Gradle root

**Files:**
- Create: `Android/settings.gradle.kts`
- Create: `Android/build.gradle.kts`
- Create: `Android/gradle.properties`
- Create: `Android/gradle/wrapper/gradle-wrapper.properties`
- Create: `Android/gradlew` (copy from `Examples/Android/gradlew`)
- Create: `Android/gradlew.bat`
- Modify: `.gitignore`

- [ ] **Step 1: Confirm the Maven group ID with the user**

If the user has not yet confirmed `io.github.kiichiio` as the group ID, ask before proceeding. The chosen group ID propagates into every Kotlin source file's package declaration and into the Swift `@_cdecl` names.

- [ ] **Step 2: Write Gradle root files**

```kotlin
// Android/settings.gradle.kts
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "swift-sheet-music-android"
include(":SheetMusicAudioAndroid")
```

```kotlin
// Android/build.gradle.kts
// Top-level: no plugins applied here; AGP / Kotlin live on the module.
```

```properties
# Android/gradle.properties
org.gradle.jvmargs=-Xmx2g
android.useAndroidX=true
kotlin.code.style=official
```

```properties
# Android/gradle/wrapper/gradle-wrapper.properties
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.9-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
```

Copy `gradlew` and `gradlew.bat` from `Examples/Android/` (Phase 4 ships them):

```bash
cp Examples/Android/gradlew Android/gradlew
cp Examples/Android/gradlew.bat Android/gradlew.bat
chmod +x Android/gradlew
```

Copy `gradle-wrapper.jar`:

```bash
mkdir -p Android/gradle/wrapper
cp Examples/Android/gradle/wrapper/gradle-wrapper.jar \
   Android/gradle/wrapper/gradle-wrapper.jar
```

- [ ] **Step 3: Update `.gitignore` to keep build artifacts out**

Append to `.gitignore`:

```
# Android Gradle module
Android/.gradle/
Android/build/
Android/*/build/
Android/local.properties
```

- [ ] **Step 4: Smoke `./gradlew tasks`**

```bash
cd Android && ./gradlew tasks --quiet
```

Expected: prints available tasks for the `:SheetMusicAudioAndroid` module placeholder (or a clean error mentioning the missing module — Task 18 fills it).

- [ ] **Step 5: Commit**

```bash
git add Android/ .gitignore
git commit -m "build(android): Gradle root for SheetMusicAudioAndroid module

settings.gradle.kts, gradle wrapper, and build.gradle.kts stub for
the top-level Android/ Kotlin Gradle root. Module(s) included below."
```

---

### Task 18: `SheetMusicAudioAndroid` module configuration

**Files:**
- Create: `Android/SheetMusicAudioAndroid/build.gradle.kts`
- Create: `Android/SheetMusicAudioAndroid/proguard-consumer.pro`
- Create: `Android/SheetMusicAudioAndroid/src/main/AndroidManifest.xml`

- [ ] **Step 1: Write the module's `build.gradle.kts`**

```kotlin
// Android/SheetMusicAudioAndroid/build.gradle.kts
plugins {
    id("com.android.library") version "8.5.2"
    kotlin("android") version "1.9.25"
}

android {
    namespace = "io.github.kiichiio.sheetmusic.audio"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("proguard-consumer.pro")
    }

    buildFeatures {
        buildConfig = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

group = "io.github.kiichiio"
version = "0.0.0-SNAPSHOT"

dependencies {
    // FluidSynth (LGPL-2.1 dynamic-link). Exact coordinate confirmed in Task 1.
    api("dev.atsushieno:fluidsynth-android:<TASK_1_VERSION>")

    // Oboe (Apache-2.0)
    api("com.google.oboe:oboe:1.9.0")

    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
}
```

(Substitute `<TASK_1_VERSION>` with the vetted version recorded in `docs/superpowers/notes/2026-05-19-fluidsynth-android-vetting.md`.)

- [ ] **Step 2: Empty proguard-consumer file (gets populated later if needed)**

```
# Android/SheetMusicAudioAndroid/proguard-consumer.pro
# Reserved for consumer ProGuard rules. Empty in v0.
```

- [ ] **Step 3: Write AndroidManifest.xml**

```xml
<!-- Android/SheetMusicAudioAndroid/src/main/AndroidManifest.xml -->
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
</manifest>
```

- [ ] **Step 4: Build the module**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:assembleDebug
```

Expected: success. The output `.aar` lives at `Android/SheetMusicAudioAndroid/build/outputs/aar/`.

- [ ] **Step 5: Commit**

```bash
git add Android/SheetMusicAudioAndroid/
git commit -m "build(android): SheetMusicAudioAndroid module skeleton

AGP library plugin, namespace io.github.kiichiio.sheetmusic.audio,
minSdk 28 / compileSdk 35. Pulls fluidsynth-android + oboe + coroutines.
No Kotlin sources yet — built to confirm Gradle configuration."
```

---

## Phase 7: Kotlin model types

Each task creates one Kotlin file mirroring an Apple / AudioCore type, with a small unit test verifying constructor + equality.

### Task 19: PlaybackState enum

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/PlaybackState.kt`
- Create: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/model/PlaybackStateTest.kt`

- [ ] **Step 1: Write file**

```kotlin
package io.github.kiichiio.sheetmusic.audio.model

/** Mirrors SheetMusicAudioCore.PlaybackState. */
enum class PlaybackState {
    STOPPED,
    PREPARED,
    PLAYING,
    PAUSED,
    EXPORTING,  // Reserved for parity; not used in v0
}
```

- [ ] **Step 2: Trivial test**

```kotlin
package io.github.kiichiio.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackStateTest {
    @Test fun hasFiveCases() {
        assertEquals(5, PlaybackState.values().size)
    }
}
```

- [ ] **Step 3: Run**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:testDebugUnitTest --tests "*PlaybackStateTest"
```

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(android-audio): PlaybackState enum"
```

---

### Task 20: MixerChannel data class

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/model/MixerChannel.kt`
- Create: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/model/MixerChannelTest.kt`

- [ ] **Step 1: File**

```kotlin
package io.github.kiichiio.sheetmusic.audio.model

data class MixerChannel(
    val staffIndex: Int,
    val displayName: String,
    val volume: Float = 1.0f,
    val isMuted: Boolean = false,
    val isSoloed: Boolean = false,
    val effectiveMute: Boolean = false,
)
```

- [ ] **Step 2: Equality test**

```kotlin
class MixerChannelTest {
    @Test fun defaultValues() {
        val c = MixerChannel(staffIndex = 0, displayName = "Staff 1")
        assertEquals(1.0f, c.volume, 0.001f)
        assertEquals(false, c.isMuted)
        assertEquals(false, c.isSoloed)
        assertEquals(false, c.effectiveMute)
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
git commit -am "feat(android-audio): MixerChannel data class"
```

---

### Task 21: ScoreCursor / NoteID / ScoreItemID data classes

**Files:**
- Create: `…/model/StaffAddress.kt`
- Create: `…/model/ScoreCursor.kt`
- Create: `…/model/NoteID.kt`
- Create: `…/model/ScoreItemID.kt`
- Test: `…/model/CursorEqualityTest.kt`

- [ ] **Step 1: Files**

```kotlin
// StaffAddress.kt
package io.github.kiichiio.sheetmusic.audio.model

sealed class StaffAddress {
    data class Part(val partIndex: Int, val staffOffset: Int) : StaffAddress()
}
```

```kotlin
// ScoreCursor.kt
data class ScoreCursor(
    val staff: StaffAddress,
    val measureIndex: Int,
    val voiceIndex: Int,
    val elementIndex: Int,
    val noteIndexInChord: Int?,
)
```

```kotlin
// NoteID.kt
data class NoteID(val cursor: ScoreCursor)
```

```kotlin
// ScoreItemID.kt
data class ScoreItemID(val cursor: ScoreCursor)
```

(If the actual Swift `StaffAddress` enum has more cases, mirror them here exactly. Run `grep -rn "enum StaffAddress" Sources/SheetMusicCore/` from the worktree to confirm.)

- [ ] **Step 2: Equality test**

```kotlin
class CursorEqualityTest {
    @Test fun cursorEqualityIsValueBased() {
        val a = ScoreCursor(StaffAddress.Part(0, 0), 0, 0, 0, 0)
        val b = ScoreCursor(StaffAddress.Part(0, 0), 0, 0, 0, 0)
        assertEquals(a, b)
        assertEquals(NoteID(a), NoteID(b))
        assertEquals(ScoreItemID(a), ScoreItemID(b))
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
git commit -am "feat(android-audio): ScoreCursor / NoteID / ScoreItemID model"
```

---

### Task 22: MetronomeBeat / Frame data classes

**Files:**
- Create: `…/model/MetronomeBeat.kt`
- Create: `…/model/Frame.kt`

- [ ] **Step 1: Files**

```kotlin
// MetronomeBeat.kt
data class MetronomeBeat(
    val tick: Long,
    val kind: Kind,
) {
    enum class Kind { DOWNBEAT, UPBEAT, SUBDIVISION }
}
```

```kotlin
// Frame.kt
data class Frame(
    val tick: Long,
    val timeSeconds: Double,
    val cursor: ScoreCursor,
)
```

- [ ] **Step 2: Equality test (one for each)**

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(android-audio): MetronomeBeat + Frame model"
```

---

### Task 23: SoundfontResolver interface + AudioBackendException sealed class

**Files:**
- Create: `…/SoundfontResolver.kt`
- Create: `…/AudioBackendException.kt`

- [ ] **Step 1: Files**

```kotlin
// SoundfontResolver.kt
package io.github.kiichiio.sheetmusic.audio

import android.net.Uri

interface SoundfontResolver {
    fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri?
    val defaultGmSoundfontUri: Uri?
}
```

```kotlin
// AudioBackendException.kt
package io.github.kiichiio.sheetmusic.audio

sealed class AudioBackendException(message: String) : Exception(message) {
    class NoSoundfont : AudioBackendException("No SoundFont available")
    class StreamUnavailable(cause: String) :
        AudioBackendException("Audio stream open failed: $cause")
    class InvalidScoreHandle :
        AudioBackendException("Score handle was not recognized")
    class EmptyScore : AudioBackendException("Score has zero staves")
    class TooManyStaves(staffCount: Int) :
        AudioBackendException("Score has $staffCount staves; v0 supports up to 16")
    class FluidSynthInit(cause: String) :
        AudioBackendException("FluidSynth initialization failed: $cause")
}
```

- [ ] **Step 2: Commit**

```bash
git commit -am "feat(android-audio): SoundfontResolver + AudioBackendException"
```

---

## Phase 8: Kotlin codecs (TDD against committed golden)

Copy the Swift-generated golden binaries into the Kotlin test resources, then write decoders that read them.

### Task 24: Copy golden binaries to Kotlin test resources

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/test/resources/golden/frame-v1.bin` (etc.)
- Create: `Android/SheetMusicAudioAndroid/build.gradle.kts` (modify: add a Gradle task to sync)

- [ ] **Step 1: Add a Gradle sync task**

Append to `Android/SheetMusicAudioAndroid/build.gradle.kts`:

```kotlin
val syncGoldenBinaries by tasks.registering(Copy::class) {
    from(rootProject.file("../Tests/SheetMusicTests/Resources/Golden/Audio"))
    into(file("src/test/resources/golden"))
}

tasks.named("processTestResources") { dependsOn(syncGoldenBinaries) }
```

- [ ] **Step 2: Verify sync works**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:syncGoldenBinaries
ls Android/SheetMusicAudioAndroid/src/test/resources/golden/
```

Expected: 6 `*.bin` files copied.

- [ ] **Step 3: Commit (the .bin files themselves are gitignored — only the Gradle task is committed)**

Append to `.gitignore`:
```
Android/SheetMusicAudioAndroid/src/test/resources/golden/
```

```bash
git add Android/SheetMusicAudioAndroid/build.gradle.kts .gitignore
git commit -m "build(android-audio): syncGoldenBinaries task copies Swift goldens"
```

---

### Task 25: BinaryReader (Kotlin)

**Files:**
- Create: `…/serialization/BinaryReader.kt`
- Create: `…/serialization/BinaryReaderTest.kt`

- [ ] **Step 1: Test**

```kotlin
class BinaryReaderTest {
    @Test fun readsLittleEndian() {
        val bytes = byteArrayOf(0xCD.toByte(), 0xAB.toByte(),
                                0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte())
        val r = BinaryReader(bytes)
        assertEquals(0xABCD, r.readU16())
        assertEquals(-1, r.readI32())
    }
}
```

- [ ] **Step 2: Implementation**

```kotlin
// BinaryReader.kt
package io.github.kiichiio.sheetmusic.audio.serialization

class BinaryReader(private val data: ByteArray) {
    private var offset = 0

    val remaining: Int get() = data.size - offset

    fun readU8(): Int {
        require(offset < data.size) { "BinaryReader underflow" }
        return data[offset++].toInt() and 0xFF
    }
    fun readU16(): Int = readU8() or (readU8() shl 8)
    fun readI32(): Int {
        var v = 0
        for (i in 0..3) v = v or (readU8() shl (i * 8))
        return v
    }
    fun readI64(): Long {
        var v = 0L
        for (i in 0..7) v = v or (readU8().toLong() shl (i * 8))
        return v
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
git commit -am "feat(android-audio): BinaryReader for codec round trip"
```

---

### Task 26: ScoreCursorCodec (Kotlin)

**Files:**
- Create: `…/serialization/ScoreCursorCodec.kt`
- Create: `…/serialization/ScoreCursorCodecTest.kt`

- [ ] **Step 1: Test against committed golden**

```kotlin
class ScoreCursorCodecTest {
    @Test fun decodesGoldenCursor() {
        val bytes = javaClass.getResourceAsStream("/golden/cursor-v1.bin")!!.readBytes()
        val r = BinaryReader(bytes)
        val cursor = ScoreCursorCodec.decode(r)
        assertEquals(StaffAddress.Part(0, 0), cursor.staff)
        assertEquals(0, cursor.measureIndex)
        assertEquals(0, cursor.voiceIndex)
        assertEquals(0, cursor.elementIndex)
        assertEquals(0, cursor.noteIndexInChord)
    }
}
```

- [ ] **Step 2: Implementation**

```kotlin
// ScoreCursorCodec.kt
package io.github.kiichiio.sheetmusic.audio.serialization

import io.github.kiichiio.sheetmusic.audio.model.ScoreCursor
import io.github.kiichiio.sheetmusic.audio.model.StaffAddress

object ScoreCursorCodec {
    const val FORMAT_VERSION = 1

    fun decode(r: BinaryReader): ScoreCursor {
        require(r.readU16() == FORMAT_VERSION) { "Cursor format mismatch" }
        return decodePayload(r)
    }

    fun decodePayload(r: BinaryReader): ScoreCursor {
        val discriminator = r.readI32()
        val staff: StaffAddress = when (discriminator) {
            0 -> {
                val partIndex = r.readI64().toInt()
                val staffOffset = r.readI64().toInt()
                StaffAddress.Part(partIndex, staffOffset)
            }
            else -> error("Unknown StaffAddress discriminator: $discriminator")
        }
        val measureIndex = r.readI32()
        val voiceIndex = r.readI32()
        val elementIndex = r.readI32()
        val n = r.readI32()
        return ScoreCursor(
            staff = staff,
            measureIndex = measureIndex,
            voiceIndex = voiceIndex,
            elementIndex = elementIndex,
            noteIndexInChord = if (n < 0) null else n,
        )
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
git commit -am "feat(android-audio): ScoreCursorCodec decoder + golden test"
```

---

### Tasks 27-30: NoteID / ScoreItemID / Frame / MetronomeBeat / StaffParams decoders

Each follows the same pattern as Task 26: read its version byte, then delegate body to a payload decoder (delegating to `ScoreCursorCodec.decodePayload` where the cursor is embedded). Test by reading the corresponding `golden/*-v1.bin` file and asserting decoded value.

For brevity, the steps are:
1. Write the test (load golden bytes; assert decoded values match the Swift-generated fixture data — same constants as in Task 16's `generateAllGoldenBinaries`).
2. Implement the decoder mirroring the Swift codec from Phase 3.
3. Run and commit per file.

Commit messages:

- `feat(android-audio): NoteIDCodec decoder + golden test`
- `feat(android-audio): ScoreItemIDCodec decoder + golden test`
- `feat(android-audio): FrameCodec decoder + golden test`
- `feat(android-audio): MetronomeBeatCodec decoder + golden test`
- `feat(android-audio): StaffParamsCodec decoder + golden test`

---

## Phase 9: JNI declarations + internal engine pieces

### Task 31: SheetMusicAudioJNI Kotlin wrapper

**Files:**
- Create: `…/jni/SheetMusicAudioJNI.kt`

- [ ] **Step 1: File**

```kotlin
package io.github.kiichiio.sheetmusic.audio.jni

internal object SheetMusicAudioJNI {
    init {
        System.loadLibrary("SheetMusicJNI")
    }

    external fun nativeRenderMidi(scoreHandle: Long): ByteArray
    external fun nativeTimelineSummary(scoreHandle: Long): LongArray
    external fun nativeFrameAtTick(scoreHandle: Long, tick: Long): ByteArray
    external fun nativeFrameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray
    external fun nativeMetronomeBeats(scoreHandle: Long): ByteArray
    external fun nativeStaffParams(scoreHandle: Long): ByteArray
    external fun nativePitchAndStaffOfNote(scoreHandle: Long, noteIdBytes: ByteArray): Long
    external fun nativeEarliestOf(scoreHandle: Long, idsBytes: ByteArray): ByteArray
}
```

- [ ] **Step 2: Build** (no test — JVM does not have `SheetMusicJNI.so`; tests that touch this go through fakes)

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:assembleDebug
```

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(android-audio): SheetMusicAudioJNI external declarations"
```

---

### Task 32: FluidSynthEngine wrapper

**Files:**
- Create: `…/synth/FluidSynthEngine.kt`
- Create: `…/synth/FluidSynthEngineTest.kt`

`FluidSynthEngine` exposes a Kotlin-friendly API over the fluidsynth-android JVM bindings, hiding raw native pointers. Inspect the chosen artifact (Task 1) for its actual class shape; the wrapper below assumes a `org.audiveris.fluidsynth.Synth` style API. Adapt to actual.

- [ ] **Step 1: Test using a fake driver**

```kotlin
class FluidSynthEngineTest {
    private class FakeSynth : SynthDriver { /* records calls */ }

    @Test fun setupCreatesOneSynthPerStaff() {
        val factory = { FakeSynth() }
        val engine = FluidSynthEngine(synthFactory = factory)
        engine.setupStaves(listOf(/* 3 StaffParams */), resolver = StubResolver())
        assertEquals(3, engine.synthCount)
    }
}
```

- [ ] **Step 2: Implement (skeleton — calls to real fluidsynth JNI added in next step)**

```kotlin
// FluidSynthEngine.kt
package io.github.kiichiio.sheetmusic.audio.synth

import io.github.kiichiio.sheetmusic.audio.SoundfontResolver
import io.github.kiichiio.sheetmusic.audio.serialization.StaffParams

internal interface SynthDriver {
    fun loadSoundFont(filePath: String, bank: Int, program: Int, isDrums: Boolean)
    fun setGain(value: Float)
    fun noteOn(channel: Int, pitch: Int, velocity: Int)
    fun noteOff(channel: Int, pitch: Int)
    fun allNotesOff()
    fun handleMidiEvent(rawEvent: Long) // packed event for fluid_synth_handle_midi_event
    fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray)
    fun close()
}

internal class FluidSynthEngine(
    private val synthFactory: () -> SynthDriver,
) {
    private val staves = mutableListOf<SynthDriver>()
    val synthCount: Int get() = staves.size

    fun setupStaves(
        staffParams: List<StaffParams>,
        resolver: SoundfontResolver,
    ) { /* iterate, create synth, resolve URI, load SF2 */ }

    fun close() { staves.forEach { it.close() }; staves.clear() }

    // … expose noteOn / noteOff / setGain / writeFloat by index …
}
```

- [ ] **Step 3: Connect to real fluidsynth-android binding (once Task 1's artifact is in deps)**

Replace `FakeSynth` with an adapter class `FluidSynthDriver` that calls the real artifact's API.

- [ ] **Step 4: Run + commit**

```bash
git commit -am "feat(android-audio): FluidSynthEngine wrapper + tests"
```

---

### Task 33: PlayerDriver wrapper

**Files:**
- Create: `…/synth/PlayerDriver.kt`
- Create: `…/synth/PlayerDriverTest.kt`

```kotlin
internal class PlayerDriver(
    private val onEvent: (channel: Int, rawEvent: Long) -> Unit,
) {
    fun load(smfBytes: ByteArray) { /* fluid_player_add_mem */ }
    fun play() { /* fluid_player_play */ }
    fun stop() { /* fluid_player_stop */ }
    fun join(timeoutMs: Long = 1000) { /* fluid_player_join */ }
    fun seekTick(tick: Long) { /* fluid_player_seek */ }
    val currentTick: Long get() = TODO() // fluid_player_get_current_tick
    fun close() { /* delete_fluid_player */ }
}
```

`onEvent` is the playback callback wired via `fluid_player_set_playback_callback`. It reads `event.channel` as the staff index, then delegates to `FluidSynthEngine.staves[channel].handleMidiEvent(rewriteChannelToZero(rawEvent))`.

- [ ] **Step 1: Test the routing logic with a fake player**

```kotlin
class PlayerDriverTest {
    @Test fun routesEventByStaffIndex() {
        val received = mutableListOf<Pair<Int, Long>>()
        val driver = PlayerDriver { ch, evt -> received += ch to evt }
        // Inject a fake event whose channel == 2
        driver.deliverForTesting(channel = 2, rawEvent = 0x123L)
        assertEquals(listOf(2 to 0x123L), received)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git commit -am "feat(android-audio): PlayerDriver with per-staff routing"
```

---

### Task 34: OboeStream wrapper

**Files:**
- Create: `…/synth/OboeStream.kt`
- Create: `…/synth/OboeStreamTest.kt`

OboeStream owns a `com.google.oboe.AudioStreamBuilder`; on `open()` it builds + starts the stream with a callback that pulls audio from `FluidSynthEngine`.

- [ ] **Step 1: Test the mix-down logic with a stub callback** (no real Oboe in unit tests; mock the callback's input/output)

- [ ] **Step 2: Implement the wrapper, leaving real Oboe initialization gated behind `isInTest = !Build.FINGERPRINT.contains("generic")` etc., or simply skip device-only paths in JVM tests**

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(android-audio): OboeStream wrapper"
```

---

### Task 35: MetronomeMixer

**Files:**
- Create: `…/synth/MetronomeMixer.kt`
- Create: `…/synth/MetronomeMixerTest.kt`

- [ ] **Step 1: Test using a fake clock + fake synth that records noteOn / noteOff**

```kotlin
class MetronomeMixerTest {
    @Test fun firesNoteOnWhenTickCrossesBeat() {
        val fake = FakeSynth()
        val mixer = MetronomeMixer(fake, beats = listOf(
            MetronomeBeat(480, DOWNBEAT),
        ))
        mixer.updateCurrentTick(0)
        assertTrue(fake.noteOns.isEmpty())
        mixer.updateCurrentTick(480)
        assertEquals(1, fake.noteOns.size)
        assertEquals(76, fake.noteOns[0].pitch) // GM woodblock high
    }
}
```

- [ ] **Step 2: Implement**

```kotlin
internal class MetronomeMixer(
    private val synth: SynthDriver,
    private val beats: List<MetronomeBeat>,
) {
    var isEnabled: Boolean = false
    var volume: Float = 1.0f
        set(v) { field = v; synth.setGain(v) }

    private var lastTick: Long = -1

    fun updateCurrentTick(tick: Long) {
        if (!isEnabled) { lastTick = tick; return }
        for (b in beats) {
            if (b.tick in (lastTick + 1)..tick) fire(b)
        }
        lastTick = tick
    }

    private fun fire(b: MetronomeBeat) {
        val pitch = when (b.kind) {
            MetronomeBeat.Kind.DOWNBEAT -> 76
            MetronomeBeat.Kind.UPBEAT -> 77
            MetronomeBeat.Kind.SUBDIVISION -> 77
        }
        val velocity = when (b.kind) {
            MetronomeBeat.Kind.DOWNBEAT -> 96
            MetronomeBeat.Kind.UPBEAT -> 72
            MetronomeBeat.Kind.SUBDIVISION -> 56
        }
        synth.noteOn(9, pitch, velocity)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(android-audio): MetronomeMixer with tick-crossing beat scheduler"
```

---

## Phase 10: AndroidPlaybackEngine assembly (TDD)

### Task 36: Engine skeleton + StateFlow declarations

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngine.kt`
- Create: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/sheetmusic/audio/AndroidPlaybackEngineTest.kt`

- [ ] **Step 1: Test that the engine exposes the expected StateFlow shape**

```kotlin
class AndroidPlaybackEngineTest {
    @Test fun initialStateIsStopped() = runTest {
        val engine = AndroidPlaybackEngine(
            context = mockContext(),
            soundfontResolver = StubResolver(),
            fluidSynthFactory = ::FakeSynth,
            oboeFactory = ::FakeOboeStream,
        )
        assertEquals(PlaybackState.STOPPED, engine.state.value)
        assertNull(engine.currentCursor.value)
        assertEquals(0.0, engine.currentTimeSeconds.value, 0.001)
    }
}
```

- [ ] **Step 2: Skeleton implementation**

```kotlin
// AndroidPlaybackEngine.kt
package io.github.kiichiio.sheetmusic.audio

import android.content.Context
import io.github.kiichiio.sheetmusic.audio.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

class AndroidPlaybackEngine internal constructor(
    private val context: Context,
    private val soundfontResolver: SoundfontResolver,
    private val fluidSynthFactory: () -> /* SynthDriver */ Any,
    private val oboeFactory: () -> /* OboeStream */ Any,
) : AutoCloseable {

    constructor(context: Context, soundfontResolver: SoundfontResolver) :
        this(context, soundfontResolver,
             fluidSynthFactory = { /* real FluidSynthDriver */ TODO() },
             oboeFactory = { /* real OboeStream */ TODO() })

    private val _state = MutableStateFlow(PlaybackState.STOPPED)
    val state: StateFlow<PlaybackState> = _state.asStateFlow()

    private val _currentCursor = MutableStateFlow<ScoreCursor?>(null)
    val currentCursor: StateFlow<ScoreCursor?> = _currentCursor.asStateFlow()

    private val _currentTimeSeconds = MutableStateFlow(0.0)
    val currentTimeSeconds: StateFlow<Double> = _currentTimeSeconds.asStateFlow()

    private val _totalTimeSeconds = MutableStateFlow(0.0)
    val totalTimeSeconds: StateFlow<Double> = _totalTimeSeconds.asStateFlow()

    private val _mixerChannels = MutableStateFlow<List<MixerChannel>>(emptyList())
    val mixerChannels: StateFlow<List<MixerChannel>> = _mixerChannels.asStateFlow()

    // Stubs filled in by subsequent tasks
    suspend fun prepare(scoreHandle: Long) { TODO("Task 37") }
    fun play(from: ScoreCursor? = null) { TODO("Task 38") }
    fun pause() { TODO("Task 38") }
    fun stop() { TODO("Task 38") }
    fun seek(to: ScoreCursor) { TODO("Task 39") }
    fun skip(seconds: Double) { TODO("Task 39") }
    fun playPreview(noteId: NoteID, durationMillis: Long = 300, velocity: Int = 96) {
        TODO("Task 40")
    }
    fun clearCursor() { _currentCursor.value = null }
    fun earliest(of: List<ScoreItemID>): ScoreItemID? { TODO("Task 40") }

    fun setMasterVolume(volume: Float) { TODO("Task 41") }
    fun setStaffMuted(staffIndex: Int, muted: Boolean) { TODO("Task 41") }
    fun setStaffSoloed(staffIndex: Int, soloed: Boolean) { TODO("Task 41") }
    fun setStaffVolume(staffIndex: Int, volume: Float) { TODO("Task 41") }

    fun setMetronomeEnabled(enabled: Boolean) { TODO("Task 42") }
    fun setMetronomeVolume(volume: Float) { TODO("Task 42") }

    fun teardown() { TODO("Task 43") }
    override fun close() = teardown()
}
```

- [ ] **Step 3: Run + commit**

```bash
git commit -am "feat(android-audio): AndroidPlaybackEngine skeleton + StateFlow"
```

---

### Task 37: `prepare()` implementation

**Files:**
- Modify: `…/AndroidPlaybackEngine.kt`
- Modify: `…/AndroidPlaybackEngineTest.kt`

- [ ] **Step 1: Test prepare populates mixer channels and emits PREPARED**

```kotlin
@Test fun prepareLoadsTimelineAndMixer() = runTest {
    val engine = AndroidPlaybackEngine(
        context = mockContext(),
        soundfontResolver = StubResolver(),
        fluidSynthFactory = ::FakeSynth,
        oboeFactory = ::FakeOboeStream,
        jniBridge = FakeJniBridge(
            timelineSummary = longArrayOf(960, 2_000_000, 480),
            staffParams = encodeStaffParams(listOf(
                StaffParams(0, 0, 0, false, 1),
                StaffParams(1, 0, 0, true, 2),
            )),
            metronomeBeats = encodeBeats(listOf(MetronomeBeat(0, DOWNBEAT))),
            midiBytes = byteArrayOf(/* minimal valid SMF */),
        ),
    )
    engine.prepare(scoreHandle = 1L)
    assertEquals(PlaybackState.PREPARED, engine.state.value)
    assertEquals(2, engine.mixerChannels.value.size)
    assertEquals(2.0, engine.totalTimeSeconds.value, 0.001)
}
```

- [ ] **Step 2: Implementation**

```kotlin
private val prepareMutex = kotlinx.coroutines.sync.Mutex()
private var scoreHandle: Long = 0
private var totalTicks: Long = 0
private lateinit var fluidSynthEngine: FluidSynthEngine
private lateinit var playerDriver: PlayerDriver
private lateinit var oboeStream: OboeStream
private lateinit var metronomeMixer: MetronomeMixer

suspend fun prepare(scoreHandle: Long) = prepareMutex.withLock {
    withContext(Dispatchers.IO) {
        val summary = jniBridge.timelineSummary(scoreHandle)
        if (summary.isEmpty()) throw AudioBackendException.InvalidScoreHandle()
        totalTicks = summary[0]
        val totalSecs = summary[1] / 1_000_000.0

        val staffBytes = jniBridge.staffParams(scoreHandle)
        val staves = StaffParamsCodec.decodeArray(staffBytes)
        if (staves.isEmpty()) throw AudioBackendException.EmptyScore()
        if (staves.size > 16) throw AudioBackendException.TooManyStaves(staves.size)

        val beatBytes = jniBridge.metronomeBeats(scoreHandle)
        val beats = MetronomeBeatCodec.decodeArray(beatBytes)

        val smfBytes = jniBridge.renderMidi(scoreHandle)

        fluidSynthEngine = FluidSynthEngine(fluidSynthFactory)
        fluidSynthEngine.setupStaves(staves, soundfontResolver, context)
        metronomeMixer = MetronomeMixer(/* dedicated synth */, beats)
        playerDriver = PlayerDriver { channel, raw ->
            fluidSynthEngine.dispatch(channel, raw)
        }
        playerDriver.load(smfBytes)
        oboeStream = oboeFactory().also { it.open(fluidSynthEngine, metronomeMixer) }

        withContext(Dispatchers.Main) {
            this@AndroidPlaybackEngine.scoreHandle = scoreHandle
            _mixerChannels.value = staves.mapIndexed { i, p ->
                MixerChannel(staffIndex = i, displayName = "Staff ${i + 1}")
            }
            _totalTimeSeconds.value = totalSecs
            _state.value = PlaybackState.PREPARED
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(android-audio): AndroidPlaybackEngine.prepare"
```

---

### Task 38: `play()` / `pause()` / `stop()` + tests

**Files:**
- Modify: `…/AndroidPlaybackEngine.kt`
- Modify: `…/AndroidPlaybackEngineTest.kt`

- [ ] **Step 1: Tests for each state transition**

```kotlin
@Test fun playTransitionsToPlaying() = runTest {
    val engine = prepareEngine()
    engine.play()
    assertEquals(PlaybackState.PLAYING, engine.state.value)
}

@Test fun pauseTransitionsToPaused() = runTest {
    val engine = prepareEngine()
    engine.play()
    engine.pause()
    assertEquals(PlaybackState.PAUSED, engine.state.value)
}

@Test fun stopTransitionsToStoppedAndClearsCursor() = runTest {
    val engine = prepareEngine()
    engine.play()
    engine.stop()
    assertEquals(PlaybackState.STOPPED, engine.state.value)
    assertNull(engine.currentCursor.value)
}
```

- [ ] **Step 2: Implementation**

```kotlin
fun play(from: ScoreCursor? = null) {
    if (_state.value == PlaybackState.EXPORTING) return
    from?.let { seek(it) }
    playerDriver.play()
    _state.value = PlaybackState.PLAYING
    startPollJob()
}

fun pause() {
    if (_state.value == PlaybackState.EXPORTING) return
    playerDriver.stop()
    stopPollJob()
    _state.value = PlaybackState.PAUSED
}

fun stop() {
    if (_state.value == PlaybackState.EXPORTING) return
    playerDriver.stop()
    playerDriver.seekTick(0)
    fluidSynthEngine.allNotesOff()
    stopPollJob()
    _state.value = PlaybackState.STOPPED
    _currentCursor.value = null
    _currentTimeSeconds.value = 0.0
}
```

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(android-audio): play / pause / stop"
```

---

### Task 39: `seek()` + `skip()` + tests

- [ ] **Step 1: Tests**

```kotlin
@Test fun seekCallsAllNotesOffAndSeekTick() = runTest {
    val engine = prepareEngine()
    engine.play()
    val cursor = /* known cursor */
    engine.seek(cursor)
    assertEquals(cursor, engine.currentCursor.value)
}
```

- [ ] **Step 2: Implementation**

```kotlin
fun seek(to: ScoreCursor) {
    if (_state.value == PlaybackState.EXPORTING) return
    val cursorBytes = ScoreCursorCodec.encode(to)
    val frameBytes = jniBridge.frameForCursor(scoreHandle, cursorBytes)
    val frame = FrameCodec.decode(frameBytes) ?: return
    fluidSynthEngine.allNotesOff()
    playerDriver.seekTick(frame.tick)
    _currentCursor.value = to
    _currentTimeSeconds.value = frame.timeSeconds
}

fun skip(seconds: Double) {
    if (_state.value == PlaybackState.EXPORTING) return
    val total = _totalTimeSeconds.value
    val target = (_currentTimeSeconds.value + seconds).coerceIn(0.0, total)
    val targetTick = (target * 1_000_000).toLong()
    // No frameAtTime helper; locate matching frame by tick via frameAtTick
    val frameBytes = jniBridge.frameAtTick(
        scoreHandle, tick = (target / total * totalTicks).toLong(),
    )
    val frame = FrameCodec.decode(frameBytes) ?: return
    fluidSynthEngine.allNotesOff()
    playerDriver.seekTick(frame.tick)
    _currentCursor.value = frame.cursor
    _currentTimeSeconds.value = frame.timeSeconds
}
```

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(android-audio): seek + skip"
```

---

### Task 40: `playPreview()` + `earliest()` + tests

- [ ] **Step 1: Tests**

```kotlin
@Test fun playPreviewSendsNoteOnAndScheduleNoteOff() = runTest {
    val engine = prepareEngine()
    val noteId = NoteID(/* known cursor */)
    engine.playPreview(noteId, durationMillis = 50)
    advanceTimeBy(60)
    val fake = engine.fluidSynthFactory() as FakeSynth
    assertEquals(1, fake.noteOns.size)
    assertEquals(1, fake.noteOffs.size)
}
```

- [ ] **Step 2: Implementation**

```kotlin
private val previewScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

fun playPreview(noteId: NoteID, durationMillis: Long, velocity: Int) {
    if (_state.value == PlaybackState.EXPORTING) return
    val packed = jniBridge.pitchAndStaffOfNote(scoreHandle, NoteIDCodec.encode(noteId))
    if (packed == -1L) return
    val pitch = ((packed.toULong() shr 32) and 0xFFFFFFFFu).toInt()
    val staffIndex = (packed.toULong() and 0xFFFFFFFFu).toInt()
    fluidSynthEngine.staves[staffIndex].noteOn(0, pitch, velocity)
    previewScope.launch {
        delay(durationMillis)
        fluidSynthEngine.staves[staffIndex].noteOff(0, pitch)
    }
}

fun earliest(of: List<ScoreItemID>): ScoreItemID? {
    val bytes = jniBridge.earliestOf(scoreHandle, ScoreItemIDCodec.encodeArray(of))
    return ScoreItemIDCodec.decodeOrNull(bytes)
}
```

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(android-audio): playPreview + earliest"
```

---

### Task 41: Mixer methods (setMasterVolume / setStaff*)

- [ ] **Step 1: Tests for mute/solo precedence (mirror spec Section "Mixer semantics")**

```kotlin
@Test fun soloOverridesMute() = runTest {
    val engine = prepareEngine()  // 3 staves
    engine.setStaffMuted(0, muted = true)
    engine.setStaffSoloed(1, soloed = true)
    val ch = engine.mixerChannels.value
    assertEquals(true, ch[0].effectiveMute)  // muted + non-soloed → mute
    assertEquals(false, ch[1].effectiveMute) // soloed → audible
    assertEquals(true, ch[2].effectiveMute)  // non-soloed → mute
}
```

- [ ] **Step 2: Implementation**

```kotlin
private var masterVolume: Float = 1.0f

fun setMasterVolume(volume: Float) {
    masterVolume = volume
    oboeStream.masterVolume = volume
}

fun setStaffMuted(staffIndex: Int, muted: Boolean) {
    updateChannel(staffIndex) { it.copy(isMuted = muted) }
}

fun setStaffSoloed(staffIndex: Int, soloed: Boolean) {
    updateChannel(staffIndex) { it.copy(isSoloed = soloed) }
}

fun setStaffVolume(staffIndex: Int, volume: Float) {
    fluidSynthEngine.staves[staffIndex].setGain(volume)
    updateChannel(staffIndex) { it.copy(volume = volume) }
}

private inline fun updateChannel(idx: Int, mutate: (MixerChannel) -> MixerChannel) {
    _mixerChannels.update { list ->
        val mut = list.toMutableList()
        mut[idx] = mutate(mut[idx])
        recomputeEffectiveMutes(mut)
    }
}

private fun recomputeEffectiveMutes(channels: MutableList<MixerChannel>): List<MixerChannel> {
    val anySoloed = channels.any { it.isSoloed && !it.isMuted }
    return channels.mapIndexed { _, c ->
        val effMute = c.isMuted || (anySoloed && !c.isSoloed)
        c.copy(effectiveMute = effMute)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(android-audio): mixer methods + solo precedence"
```

---

### Task 42: Metronome methods

- [ ] **Step 1: Test**

```kotlin
@Test fun setMetronomeEnabledTogglesMixer() = runTest {
    val engine = prepareEngine()
    engine.setMetronomeEnabled(true)
    assertTrue(engine.metronomeMixerForTesting.isEnabled)
}
```

- [ ] **Step 2: Implementation**

```kotlin
fun setMetronomeEnabled(enabled: Boolean) {
    metronomeMixer.isEnabled = enabled
}

fun setMetronomeVolume(volume: Float) {
    metronomeMixer.volume = volume
}
```

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(android-audio): metronome on/off + volume"
```

---

### Task 43: Cursor poll job + teardown

- [ ] **Step 1: Test cursor updates fire while PLAYING**

```kotlin
@Test fun cursorUpdatesDuringPlayback() = runTest {
    val engine = prepareEngine()
    engine.play()
    // Advance fake clock past 33ms → poll triggers nativeFrameAtTick
    advanceTimeBy(40)
    val fake = engine.jniBridgeForTesting as FakeJniBridge
    assertTrue(fake.frameAtTickCalls > 0)
}
```

- [ ] **Step 2: Implement poll job**

```kotlin
private var pollJob: Job? = null
private val pollScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

private fun startPollJob() {
    pollJob?.cancel()
    pollJob = pollScope.launch {
        while (isActive && _state.value == PlaybackState.PLAYING) {
            val tick = playerDriver.currentTick
            val frameBytes = jniBridge.frameAtTick(scoreHandle, tick)
            val frame = FrameCodec.decodeOrNull(frameBytes)
            withContext(Dispatchers.Main) {
                _currentCursor.value = frame?.cursor
                _currentTimeSeconds.value = frame?.timeSeconds ?: 0.0
            }
            if (tick >= totalTicks) {
                withContext(Dispatchers.Main) { stop() }
                break
            }
            metronomeMixer.updateCurrentTick(tick)
            delay(33)
        }
    }
}

private fun stopPollJob() { pollJob?.cancel(); pollJob = null }
```

- [ ] **Step 3: Implement teardown**

```kotlin
fun teardown() {
    stopPollJob()
    pollScope.cancel()
    previewScope.cancel()
    if (::oboeStream.isInitialized) oboeStream.close()
    if (::playerDriver.isInitialized) {
        playerDriver.stop()
        playerDriver.join(timeoutMs = 1000)
        playerDriver.close()
    }
    if (::fluidSynthEngine.isInitialized) fluidSynthEngine.close()
    _state.value = PlaybackState.STOPPED
}
```

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(android-audio): cursor poll job + teardown lifecycle"
```

---

## Phase 11: Example app wiring

### Task 44: Examples/Android composite build

**Files:**
- Modify: `Examples/Android/settings.gradle.kts`
- Modify: `Examples/Android/app/build.gradle.kts`

- [ ] **Step 1: Add includeBuild + dependency substitution**

```kotlin
// Examples/Android/settings.gradle.kts (append)
includeBuild("../../Android") {
    dependencySubstitution {
        substitute(module("io.github.kiichiio:sheet-music-audio-android"))
            .using(project(":SheetMusicAudioAndroid"))
    }
}
```

```kotlin
// Examples/Android/app/build.gradle.kts (append to dependencies block)
implementation("io.github.kiichiio:sheet-music-audio-android:0.0.0-SNAPSHOT")
```

- [ ] **Step 2: Build the example app**

```bash
cd Examples/Android && ./gradlew :app:assembleDebug
```

Expected: success. `app-debug.apk` is produced at `Examples/Android/app/build/outputs/apk/debug/`.

- [ ] **Step 3: Commit**

```bash
git commit -am "build(examples-android): include SheetMusicAudioAndroid via composite"
```

---

### Task 45: AudioViewModel + Compose UI

**Files:**
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/AudioViewModel.kt`
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/MainActivity.kt` (or the existing ScoreViewModel) to instantiate AudioViewModel

- [ ] **Step 1: Write AudioViewModel**

```kotlin
class AudioViewModel(application: Application) : AndroidViewModel(application) {
    val engine = AndroidPlaybackEngine(application, AssetSoundfontResolver(application))

    fun preparePlayback(scoreHandle: Long) {
        viewModelScope.launch { engine.prepare(scoreHandle) }
    }

    override fun onCleared() {
        engine.teardown()
        super.onCleared()
    }
}
```

- [ ] **Step 2: Implement `AssetSoundfontResolver`** — reads `gm.sf2` from `app/src/main/assets/` (developer-supplied per Phase 4 Quickstart).

- [ ] **Step 3: Build the app**

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(examples-android): wire AudioViewModel into the Compose example"
```

---

### Task 46: Compose Play / Pause / Stop / Seek UI

- [ ] **Step 1: Add buttons that call engine.play / pause / stop**
- [ ] **Step 2: Show cursor position by collecting `engine.currentCursor` and `engine.currentTimeSeconds` via `collectAsState()`**
- [ ] **Step 3: Tap on a note in the existing Score canvas dispatches `engine.seek(cursor)`**
- [ ] **Step 4: Commit**

```bash
git commit -am "feat(examples-android): Play / Pause / Stop / Seek UI"
```

---

### Task 47: Compose Mixer + Metronome UI

- [ ] **Step 1: Per-staff mute / solo toggle + volume slider that calls engine.setStaffMuted / setStaffSoloed / setStaffVolume**
- [ ] **Step 2: Master volume slider**
- [ ] **Step 3: Metronome on/off + volume slider**
- [ ] **Step 4: Commit**

```bash
git commit -am "feat(examples-android): mixer + metronome UI"
```

---

## Phase 12: Smoke test + docs

### Task 48: SMOKE_TEST.md

**Files:**
- Create: `Examples/Android/SMOKE_TEST.md`

- [ ] **Step 1: Copy the checklist from the spec's "Manual audible smoke" section into the file**
- [ ] **Step 2: Commit**

```bash
git commit -am "docs(examples-android): SMOKE_TEST.md manual checklist"
```

---

### Task 49: Android/SheetMusicAudioAndroid/README.md

**Files:**
- Create: `Android/SheetMusicAudioAndroid/README.md`

- [ ] **Step 1: Write README**

Content covers:
- Quickstart Gradle dependency
- `AndroidPlaybackEngine` minimal example
- `SoundfontResolver` Apple-Kotlin mapping table
- ABI matrix (arm64-v8a, x86_64)
- 16-staff limit + rationale
- License: LGPL transitive via fluidsynth-android, Apache via oboe

- [ ] **Step 2: Commit**

```bash
git commit -am "docs(android-audio): README with quickstart + resolver mapping"
```

---

### Task 50: CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update "Library layout" to include `Android/SheetMusicAudioAndroid/`**

In the library layout ASCII diagram, append:

```
Android/SheetMusicAudioAndroid    (Kotlin Gradle module, .aar artifact;
                                   AndroidPlaybackEngine via FluidSynth + Oboe;
                                   peer to SheetMusicAudioApple)
```

- [ ] **Step 2: Update Android build section**

Change "UI / PDF remain Apple-only pending Phase 4 (Android backend)" to:

```
Audio playback on Android is delivered via the Kotlin Gradle module
`Android/SheetMusicAudioAndroid/` (FluidSynth-android + Oboe). UI / PDF
remain Apple-only.
```

- [ ] **Step 3: Commit**

```bash
git commit -am "docs(claude): Phase 4 audio backend now ships"
```

---

### Task 51: Memory update

- [ ] **Step 1: Update memory `project_android_port_roadmap`**

Mark Phase 4 audio as done with the date. Add a Phase 5 entry covering loop / rate / export / Maven publication as future work.

- [ ] **Step 2: Commit**

```bash
git commit -am "memory: Phase 4 audio backend complete"
```

---

## Phase 13: CI

### Task 52: GitHub Actions Gradle workflow

**Files:**
- Create: `.github/workflows/android-audio.yml`

- [ ] **Step 1: Write workflow**

```yaml
name: Android audio module

on:
  push:
    branches: [main]
    paths:
      - 'Android/**'
      - 'Sources/SheetMusicAndroidJNI/**'
      - '.github/workflows/android-audio.yml'
  pull_request:
    paths:
      - 'Android/**'
      - 'Sources/SheetMusicAndroidJNI/**'

jobs:
  kotlin-unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17
      - uses: gradle/actions/setup-gradle@v3
      - name: Run unit tests
        working-directory: Android
        run: ./gradlew :SheetMusicAudioAndroid:testDebugUnitTest --info

  android-assemble:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17
      - uses: android-actions/setup-android@v3
      - uses: gradle/actions/setup-gradle@v3
      - name: Assemble release AAR
        working-directory: Android
        run: ./gradlew :SheetMusicAudioAndroid:assembleRelease
```

- [ ] **Step 2: Push branch, watch CI green**

- [ ] **Step 3: Commit**

```bash
git commit -am "ci(android-audio): Gradle unit-test + assemble workflow"
```

---

## Phase 14: Validation + merge

### Task 53: Full Swift test suite

```bash
swift test
```

Expected: all green, no Apple-side regressions.

- [ ] **Step 1: Run + verify, no commit (gates merge)**

---

### Task 54: Android cross-compile + device test

```bash
TOOLCHAINS=org.swift.632202605101a \
SWIFT_SHEET_MUSIC_ANDROID=1 \
swift build --swift-sdk aarch64-unknown-linux-android28 --build-tests
Scripts/android-test.sh aarch64
```

Expected: Foundation-only tests green on device. New audio bridge tests run on Apple host only.

- [ ] **Step 1: Run + verify**

---

### Task 55: Gradle unit tests

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:testDebugUnitTest
```

Expected: every Kotlin test green.

- [ ] **Step 1: Run + verify**

---

### Task 56: Manual smoke on emulator + device

Run through `Examples/Android/SMOKE_TEST.md` on:
- arm64-v8a physical device
- x86_64 emulator

- [ ] **Step 1: Execute checklist, record any failures**
- [ ] **Step 2: If a checklist item fails, file a follow-up task with the spec's "Errors / edge cases" section as triage reference**

---

### Task 57: Merge to main

- [ ] **Step 1: Open PR from `feature/android-audio-backend` → `main`**
- [ ] **Step 2: Reference spec doc in PR description**
- [ ] **Step 3: After review, merge via `--no-ff` to preserve the feature branch history**
- [ ] **Step 4: Delete the worktree**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music \
    worktree remove .claude/worktrees/android-audio-backend
```

---

## Spec coverage matrix

| Spec section | Tasks |
|---|---|
| Architecture | T0, T17–18, T36 |
| Swift bridge (8–10 @_cdecl) | T11–15 |
| SMF preprocessing | T11 |
| Serialization format | T5–10, T16, T24–30 |
| Kotlin model types | T19–23 |
| Kotlin internals (FluidSynthEngine / PlayerDriver / OboeStream / MetronomeMixer) | T32–35 |
| AndroidPlaybackEngine public API | T36–43 |
| Mixer semantics | T41 |
| Staff count limit | T37 |
| Cursor / state propagation | T43 |
| Prepare / Playback / Preview / Seek / Mixer / Metronome flows | T37–42 |
| Errors / edge cases | T37 (TooManyStaves / EmptyScore / InvalidScoreHandle); T43 (teardown ordering); T23 (exception types) |
| `SoundfontResolver` cross-platform naming | T23, T49 |
| Maven dep vetting | T1 |
| Apple regression | T53 |
| Android cross-compile | T54 |
| Gradle CI | T52, T55 |
| Manual audible smoke | T48, T56 |
| Alternative architectures considered | T1 step 3 |
| CLAUDE.md update | T50 |
| Memory update | T51 |

(Self-review confirms every spec section maps to at least one task.)
