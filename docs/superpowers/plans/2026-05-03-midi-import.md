# MIDI Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `.mid` (SMF) → `Score` import pipeline to `SheetMusicMIDI`, including conservative onset-grid quantization with tuplet detection, statistical swing detection, narrow pitch-bend → glissando, and an example-app file-picker entry. Round-trips MIDI produced by the existing `MidiRenderer`.

**Architecture:** Six-pass pipeline (`MidiReader` → `TrackPartitioner` → `SwingAnalyzer` → `BarSegmenter` → `MeasureQuantizer` → `ScoreAssembler`) producing the existing `Score` model. Public façade `MidiImporter` exposes both `throws` and `async throws` overloads; swing detection consults a caller-supplied resolver closure.

**Tech Stack:** Swift 6, Swift Testing (`@Test`, `#expect`), SPM, no external deps. Build with `swift build` / `swift test`. Tests live in `Tests/SheetMusicTests/`.

**Spec:** `docs/superpowers/specs/2026-05-03-midi-import-design.md`

---

## Phase A — Reader (Pass 1)

The codebase already has a private `SMFReader` test helper at `Tests/SheetMusicTests/Helpers/SMFReader.swift`. Phase A promotes it to a public `MidiReader` in Sources, fills in pitch-bend handling (currently dropped), and rejects Format 2 / SMPTE division.

### Task A1: Move and extend `SMFReader` → public `MidiReader`

**Files:**
- Create: `Sources/SheetMusicMIDI/IO/MidiReader.swift`
- Delete: `Tests/SheetMusicTests/Helpers/SMFReader.swift` (moved)
- Modify: `Tests/SheetMusicTests/SMFReaderTests.swift` (rename references)
- Modify: `Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift` (rename references)
- Modify: `Tests/SheetMusicTests/MusicXMLUnpitchedTests.swift` (rename references)

- [ ] **Step 1: Write the failing tests for the new behaviour**

Create `Tests/SheetMusicTests/MidiReaderTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiReaderTests {
    /// Build an SMF byte stream "by hand" so we don't depend on MidiWriter.
    private static func makeSMF(format: UInt16, division: UInt16, tracks: [Data]) -> Data {
        var data = Data()
        data.append(contentsOf: "MThd".utf8)
        data.append(contentsOf: [0, 0, 0, 6])
        data.append(UInt8((format >> 8) & 0xFF)); data.append(UInt8(format & 0xFF))
        data.append(UInt8((tracks.count >> 8) & 0xFF)); data.append(UInt8(tracks.count & 0xFF))
        data.append(UInt8((division >> 8) & 0xFF)); data.append(UInt8(division & 0xFF))
        for track in tracks {
            data.append(contentsOf: "MTrk".utf8)
            let n = UInt32(track.count)
            data.append(UInt8((n >> 24) & 0xFF))
            data.append(UInt8((n >> 16) & 0xFF))
            data.append(UInt8((n >> 8) & 0xFF))
            data.append(UInt8(n & 0xFF))
            data.append(track)
        }
        return data
    }

    private static var emptyTrack: Data {
        // delta=0, FF 2F 00 (end of track)
        Data([0x00, 0xFF, 0x2F, 0x00])
    }

    @Test func rejectsFormat2() {
        let bytes = Self.makeSMF(format: 2, division: 480, tracks: [Self.emptyTrack])
        #expect(throws: SheetMusicError.self) {
            _ = try MidiReader.read(bytes)
        }
    }

    @Test func rejectsSMPTEDivision() {
        // SMPTE division has top bit set: e.g. 0xE728 = -25 fps, 40 ticks/frame
        let bytes = Self.makeSMF(format: 1, division: 0xE728, tracks: [Self.emptyTrack])
        #expect(throws: SheetMusicError.self) {
            _ = try MidiReader.read(bytes)
        }
    }

    @Test func decodesPitchBend() throws {
        // delta=0, status=0xE0, lsb=0x40, msb=0x60, then end of track.
        let track = Data([0x00, 0xE0, 0x40, 0x60, 0x00, 0xFF, 0x2F, 0x00])
        let bytes = Self.makeSMF(format: 0, division: 480, tracks: [track])
        let file = try MidiReader.read(bytes)
        let pitchBendValue = (0x60 << 7) | 0x40 // = 12352
        let expected = MidiEvent.pitchBend(channel: 0, value: pitchBendValue)
        #expect(file.tracks[0].events.contains { $0.event == expected })
    }

    @Test func rejectsTruncatedHeader() {
        let truncated = Data([0x4D, 0x54, 0x68])
        #expect(throws: SheetMusicError.self) {
            _ = try MidiReader.read(truncated)
        }
    }

    @Test func acceptsRunningStatus() throws {
        // Track: noteOn (0x90 ch0), then running-status delta+two-byte payload.
        // delta=0, 0x90 0x3C 0x40, delta=10, 0x3E 0x40 (running status), end of track
        let track = Data([
            0x00, 0x90, 0x3C, 0x40,
            0x0A, 0x3E, 0x40,
            0x00, 0xFF, 0x2F, 0x00
        ])
        let bytes = Self.makeSMF(format: 0, division: 480, tracks: [track])
        let file = try MidiReader.read(bytes)
        let onEvents = file.tracks[0].events.compactMap { ev -> Int? in
            if case let .noteOn(_, pitch, _) = ev.event { return pitch } else { return nil }
        }
        #expect(onEvents == [60, 62])
    }
}
```

- [ ] **Step 2: Verify tests fail**

```
swift test --filter MidiReaderTests
```

Expected: compile failure (`MidiReader` undefined).

- [ ] **Step 3: Create `Sources/SheetMusicMIDI/IO/MidiReader.swift`**

Move the existing `SMFReader` body, rename to `MidiReader`, make `public`, switch errors to `SheetMusicError`, add Format 2 / SMPTE rejection, add pitch-bend decoding:

```swift
import Foundation
import SheetMusicCore

/// Reads SMF (format 0/1) bytes back into a `MidiFile`. Supports
/// running status, every channel-voice event the renderer can emit,
/// and a permissive set of meta events. Unknown meta and SysEx are
/// silently skipped — the same posture as the MSCX parser.
public enum MidiReader {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    public static func read(_ data: Data) throws -> MidiFile {
        var cursor = 0
        func require(_ n: Int) throws {
            guard cursor + n <= data.count else {
                throw SheetMusicError.malformedScore(
                    reason: "SMF truncated at offset \(cursor)"
                )
            }
        }
        func readUInt8() throws -> UInt8 {
            try require(1); defer { cursor += 1 }; return data[cursor]
        }
        func readUInt16BE() throws -> UInt16 {
            try require(2); defer { cursor += 2 }
            return (UInt16(data[cursor]) << 8) | UInt16(data[cursor + 1])
        }
        func readUInt32BE() throws -> UInt32 {
            try require(4); defer { cursor += 4 }
            return (UInt32(data[cursor]) << 24)
                | (UInt32(data[cursor + 1]) << 16)
                | (UInt32(data[cursor + 2]) << 8)
                | UInt32(data[cursor + 3])
        }
        func readBytes(_ n: Int) throws -> Data {
            try require(n); defer { cursor += n }
            return data.subdata(in: cursor ..< (cursor + n))
        }
        func readVLQ() throws -> Int {
            var v = 0
            for _ in 0 ..< 4 {
                let b = try readUInt8()
                v = (v << 7) | Int(b & 0x7F)
                if b & 0x80 == 0 { return v }
            }
            throw SheetMusicError.malformedScore(reason: "VLQ too long")
        }

        guard try readBytes(4) == Data("MThd".utf8) else {
            throw SheetMusicError.malformedScore(reason: "missing MThd header")
        }
        let headerLen = try readUInt32BE()
        guard headerLen == 6 else {
            throw SheetMusicError.malformedScore(reason: "unexpected MThd length \(headerLen)")
        }
        let format = try Int(readUInt16BE())
        let ntracks = try Int(readUInt16BE())
        let divisionRaw = try readUInt16BE()

        guard format == 0 || format == 1 else {
            throw SheetMusicError.unsupportedFeature(name: "MIDI format \(format)", location: nil)
        }
        guard divisionRaw & 0x8000 == 0 else {
            throw SheetMusicError.unsupportedFeature(
                name: "SMPTE timecode division", location: nil
            )
        }
        let division = Int(divisionRaw)

        var tracks: [MidiTrack] = []
        for _ in 0 ..< ntracks {
            guard try readBytes(4) == Data("MTrk".utf8) else {
                throw SheetMusicError.malformedScore(reason: "missing MTrk")
            }
            let bodyLen = try Int(readUInt32BE())
            let bodyEnd = cursor + bodyLen
            var events: [TimedMidiEvent] = []
            var tick = 0
            var runningStatus: UInt8 = 0
            while cursor < bodyEnd {
                let delta = try readVLQ()
                tick += delta
                var status = try readUInt8()
                if status < 0x80 {
                    cursor -= 1
                    status = runningStatus
                } else if status < 0xF0 {
                    runningStatus = status
                }
                let channel = Int(status & 0x0F)
                switch status & 0xF0 {
                case 0x80:
                    let pitch = try Int(readUInt8()), vel = try Int(readUInt8())
                    events.append(TimedMidiEvent(
                        tick: tick,
                        event: .noteOff(channel: channel, pitch: pitch, velocity: vel)
                    ))
                case 0x90:
                    let pitch = try Int(readUInt8()), vel = try Int(readUInt8())
                    let event: MidiEvent = vel == 0
                        ? .noteOff(channel: channel, pitch: pitch, velocity: 0)
                        : .noteOn(channel: channel, pitch: pitch, velocity: vel)
                    events.append(TimedMidiEvent(tick: tick, event: event))
                case 0xA0:
                    _ = try readUInt8(); _ = try readUInt8()
                case 0xB0:
                    let cc = try Int(readUInt8()), value = try Int(readUInt8())
                    events.append(TimedMidiEvent(
                        tick: tick,
                        event: .controlChange(channel: channel, controller: cc, value: value)
                    ))
                case 0xC0:
                    let prog = try Int(readUInt8())
                    events.append(TimedMidiEvent(
                        tick: tick,
                        event: .programChange(channel: channel, program: prog)
                    ))
                case 0xD0:
                    _ = try readUInt8()
                case 0xE0:
                    let lsb = try Int(readUInt8()), msb = try Int(readUInt8())
                    events.append(TimedMidiEvent(
                        tick: tick,
                        event: .pitchBend(channel: channel, value: (msb << 7) | lsb)
                    ))
                default:
                    if status == 0xFF {
                        let metaType = try readUInt8()
                        let len = try readVLQ()
                        let payload = try readBytes(len)
                        try parseMeta(
                            metaType: metaType, payload: payload, len: len,
                            tick: tick, into: &events
                        )
                    } else if status == 0xF0 || status == 0xF7 {
                        let len = try readVLQ()
                        cursor += len
                    } else {
                        throw SheetMusicError.malformedScore(
                            reason: "unknown status 0x\(String(status, radix: 16))"
                        )
                    }
                }
            }
            tracks.append(MidiTrack(events: events))
        }

        return MidiFile(division: division, format: format, tracks: tracks)
    }

    private static func parseMeta(
        metaType: UInt8,
        payload: Data,
        len: Int,
        tick: Int,
        into events: inout [TimedMidiEvent]
    ) throws {
        let start = payload.startIndex
        switch metaType {
        case 0x03:
            // String(decoding:as:) replaces invalid UTF-8 with U+FFFD,
            // which is the permissive behaviour we want for SMF.
            // swiftlint:disable:next non_optional_string_data_conversion optional_data_string_conversion
            let name = String(decoding: payload, as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
            events.append(TimedMidiEvent(tick: tick, event: .meta(.trackName(name))))
        case 0x06:
            // swiftlint:disable:next non_optional_string_data_conversion optional_data_string_conversion
            let text = String(decoding: payload, as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
            events.append(TimedMidiEvent(tick: tick, event: .meta(.marker(text))))
        case 0x21 where len == 1:
            events.append(TimedMidiEvent(
                tick: tick,
                event: .meta(.portChange(port: Int(payload[start])))
            ))
        case 0x2F:
            events.append(TimedMidiEvent(tick: tick, event: .endOfTrack))
        case 0x51 where len == 3:
            let micros = (Int(payload[start]) << 16)
                | (Int(payload[start + 1]) << 8)
                | Int(payload[start + 2])
            events.append(TimedMidiEvent(
                tick: tick,
                event: .meta(.tempo(microsecondsPerQuarter: micros))
            ))
        case 0x58 where len == 4:
            let n = Int(payload[start])
            let d = 1 << Int(payload[start + 1])
            let cc = Int(payload[start + 2])
            let t = Int(payload[start + 3])
            events.append(TimedMidiEvent(tick: tick, event: .meta(.timeSignature(
                numerator: n, denominator: d, clocksPerClick: cc, thirtySecondsPerQuarter: t
            ))))
        case 0x59 where len == 2:
            let sf = Int(Int8(bitPattern: payload[start]))
            let isMinor = payload[start + 1] != 0
            events.append(TimedMidiEvent(
                tick: tick,
                event: .meta(.keySignature(sharpsFlats: sf, isMinor: isMinor))
            ))
        default:
            break
        }
    }
}
```

- [ ] **Step 4: Update existing call sites**

Replace `SMFReader` with `MidiReader` in three test files. Each uses `try SMFReader.read(...)`; change to `try MidiReader.read(...)`. Files:

- `Tests/SheetMusicTests/SMFReaderTests.swift` — also rename the suite to `MidiReaderRoundTripTests` (just the type name) so it doesn't collide with the new `MidiReaderTests`.
- `Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift`
- `Tests/SheetMusicTests/MusicXMLUnpitchedTests.swift`

Then delete `Tests/SheetMusicTests/Helpers/SMFReader.swift`.

- [ ] **Step 5: Run all tests**

```
swift test
```

Expected: PASS for everything (including new `MidiReaderTests` and renamed `MidiReaderRoundTripTests`).

- [ ] **Step 6: Commit**

```
git add Sources/SheetMusicMIDI/IO/MidiReader.swift \
        Tests/SheetMusicTests/MidiReaderTests.swift \
        Tests/SheetMusicTests/SMFReaderTests.swift \
        Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift \
        Tests/SheetMusicTests/MusicXMLUnpitchedTests.swift
git rm Tests/SheetMusicTests/Helpers/SMFReader.swift
git commit
```

Commit message:

```
feat(midi): promote SMFReader to public MidiReader

Adds Format 2 / SMPTE rejection and pitch-bend decoding (the test
helper dropped both). Move from Tests/Helpers to Sources/IO so it
can serve as Pass 1 of the upcoming MIDI import pipeline.
```

---

## Phase B — Public types and façade scaffolding

Stub out `MidiImportOptions`, `SwingDetection`, `SwingResolution`, `MidiImporter`, and the internal pipeline types. The façade returns an empty `Score` for now; subsequent phases fill in the passes.

### Task B1: Public option / detection / resolution types

**Files:**
- Create: `Sources/SheetMusicMIDI/Import/MidiImportOptions.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation
import SheetMusicCore

/// Options controlling MIDI import behaviour. All fields have
/// defaults that produce a reasonable Score from a typical
/// notation-style SMF (DAW exports, MuseScore exports).
public struct MidiImportOptions: Sendable {
    /// Smallest binary subdivision the quantizer will produce.
    /// Onsets finer than this snap to the grid (or to a tuplet).
    public var quantizeGrid: NoteDuration = .sixteenth

    /// Onset fit tolerance in ticks. `nil` means `division / 16`
    /// (= 30 ticks at 480 PPQ).
    public var onsetTolerance: Int? = nil

    /// Tuplet ratios attempted, in priority order. `[]` disables
    /// tuplet detection (everything force-snaps to the binary grid).
    public var tupletRatios: [TupletRatio] = [
        TupletRatio(actual: 3, normal: 2),
        TupletRatio(actual: 5, normal: 4),
        TupletRatio(actual: 7, normal: 4)
    ]

    /// Pitch-bend → Glissando detection. Bend range is fixed at 12
    /// semitones (matching `MidiRenderer`'s pitch-bend range header).
    public var detectGlissando: Bool = true

    /// Sync resolver, used by the non-async parse path.
    public var resolveSwing: (@Sendable (SwingDetection) -> SwingResolution)? = nil

    /// Async resolver, used by the async parse path. Falls back to
    /// `resolveSwing` if `nil` (and that is also `nil` → no swing
    /// rewrite).
    public var resolveSwingAsync: (@Sendable (SwingDetection) async -> SwingResolution)? = nil

    public init() {}
}

/// Immutable tuplet ratio descriptor used in `MidiImportOptions`.
/// Tuple syntax (`(actual: Int, normal: Int)`) doesn't conform to
/// `Sendable` cleanly across Swift 6 boundaries, so we wrap it.
public struct TupletRatio: Sendable, Equatable {
    public let actual: Int
    public let normal: Int

    public init(actual: Int, normal: Int) {
        precondition(actual > 0 && normal > 0, "Tuplet ratio must be positive")
        self.actual = actual
        self.normal = normal
    }
}

/// Surfaced to the caller when statistical analysis suggests the
/// MIDI was performed with swing. The resolver decides whether to
/// straighten the timing or keep it as-is.
public struct SwingDetection: Sendable {
    public let trackIndex: Int
    public let measureRange: Range<Int>
    /// 1.0 = straight, 2.0 ≈ 2:1 swing, 1.5 ≈ loose swing.
    public let estimatedRatio: Double
    /// 0.0..1.0 from sample size and dispersion.
    public let confidence: Double
    public let sampleSize: Int

    public init(
        trackIndex: Int,
        measureRange: Range<Int>,
        estimatedRatio: Double,
        confidence: Double,
        sampleSize: Int
    ) {
        self.trackIndex = trackIndex
        self.measureRange = measureRange
        self.estimatedRatio = estimatedRatio
        self.confidence = confidence
        self.sampleSize = sampleSize
    }
}

public enum SwingResolution: Sendable {
    /// Rewrite tick offsets so back-eighths land on beat midpoints.
    case treatAsSwing
    /// Leave timing untouched — D' will likely produce
    /// triplet-quarter+eighth pairs.
    case treatAsWritten
}
```

- [ ] **Step 2: Build**

```
swift build
```

Expected: success (no test changes yet).

- [ ] **Step 3: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImportOptions.swift
git commit -m "feat(midi): add MidiImportOptions / SwingDetection / SwingResolution"
```

### Task B2: `MidiImporter` façade with stub return

**Files:**
- Create: `Sources/SheetMusicMIDI/Import/MidiImporter.swift`
- Create: `Sources/SheetMusicMIDI/Import/Internal.swift`
- Test: `Tests/SheetMusicTests/MidiImporterFaçadeTests.swift`

- [ ] **Step 1: Write a smoke test**

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterFaçadeTests {
    @Test func parsesEmptyFormat0AsEmptyScore() throws {
        // Minimal valid SMF: format 0, division 480, one empty MTrk.
        let bytes = Data([
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x04,
            0x00, 0xFF, 0x2F, 0x00
        ])
        let score = try MidiImporter.parse(bytes)
        #expect(score.division == 480)
        #expect(score.parts.isEmpty)
        #expect(score.staves.isEmpty)
    }

    @Test func usesSourceFilenameAsTitle() throws {
        let bytes = Data([
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x04,
            0x00, 0xFF, 0x2F, 0x00
        ])
        let score = try MidiImporter.parse(bytes, sourceFilename: "MySong")
        #expect(score.metaTags["workTitle"] == "MySong")
    }
}
```

- [ ] **Step 2: Run test, expect failure (undefined symbol)**

```
swift test --filter MidiImporterFaçadeTests
```

- [ ] **Step 3: Create `Sources/SheetMusicMIDI/Import/Internal.swift`**

```swift
import Foundation
import SheetMusicCore

/// One channel-coherent slice of an SMF track. Pass 2 produces
/// these from `MidiFile.tracks`; subsequent passes consume them.
struct ImportTrack {
    var trackIndex: Int          // SMF track index this came from
    var trackName: String?       // first FF 03 within the slice
    var isDrums: Bool            // true → channel-10-only slice
    var programChange: Int?      // first program change observed
    var events: [TimedMidiEvent] // sorted by tick, includes meta events
}

/// One measure's worth of one ImportTrack's events plus crossing-note
/// records. Pass 4 produces these.
struct ImportMeasure {
    var startTick: Int
    var endTick: Int
    var measureIndex: Int
    var timeSignature: TimeSignature
    var events: [TimedMidiEvent]
    /// Notes sounding *into* this measure that started in an earlier
    /// measure. Pass 6 turns each into a tieBack-marked chord at the
    /// measure head.
    var carryIns: [CarriedNote]
    /// Notes that *leave* this measure unfinished (noteOff happens in
    /// a later measure). Pass 6 emits a tieForward on the final chord.
    var carryOuts: [CarriedNote]
}

struct CarriedNote: Equatable {
    var pitch: Int
    var channel: Int
    var sourceMeasureIndex: Int
    var noteOnTick: Int
    var noteOffTick: Int
}

/// Output of Pass 5 for a single measure: voice elements plus tuplet
/// ranges (referencing element indices).
struct QuantizedMeasure {
    var elements: [VoiceElement]
    var tuplets: [Tuplet]
}
```

- [ ] **Step 4: Create `Sources/SheetMusicMIDI/Import/MidiImporter.swift`**

```swift
import Foundation
import SheetMusicCore

/// Public façade for reading SMF bytes into a `Score`.
///
/// The `parse` overloads run a six-pass pipeline:
///   1. `MidiReader` — SMF bytes → `MidiFile`
///   2. `TrackPartitioner` — split tracks into channel-coherent
///      slices (drums separated)
///   3. `SwingAnalyzer` — optional swing detection + resolver
///   4. `BarSegmenter` — split into per-measure events
///   5. `MeasureQuantizer` — D' onset-grid / tuplet fit
///   6. `ScoreAssembler` — voicing, ties, glissando, meta routing
public enum MidiImporter {
    public static func parse(
        _ midiData: Data,
        options: MidiImportOptions = .init(),
        sourceFilename: String? = nil
    ) throws -> Score {
        let file = try MidiReader.read(midiData)
        return try assembleSync(
            file: file, options: options, sourceFilename: sourceFilename
        )
    }

    public static func parse(
        _ midiData: Data,
        options: MidiImportOptions,
        sourceFilename: String? = nil
    ) async throws -> Score {
        let file = try MidiReader.read(midiData)
        return try await assembleAsync(
            file: file, options: options, sourceFilename: sourceFilename
        )
    }

    // MARK: - Internal entry points (filled in over the following tasks)

    static func assembleSync(
        file: MidiFile,
        options: MidiImportOptions,
        sourceFilename: String?
    ) throws -> Score {
        // Phases C–F implement these. For now: emit a Score with
        // only the title resolved from `sourceFilename`.
        var meta: [String: String] = [:]
        if let title = sourceFilename, !title.isEmpty {
            meta["workTitle"] = title
        }
        return Score(division: file.division, metaTags: meta)
    }

    static func assembleAsync(
        file: MidiFile,
        options: MidiImportOptions,
        sourceFilename: String?
    ) async throws -> Score {
        try assembleSync(file: file, options: options, sourceFilename: sourceFilename)
    }
}
```

- [ ] **Step 5: Run tests**

```
swift test --filter MidiImporterFaçadeTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter.swift \
        Sources/SheetMusicMIDI/Import/Internal.swift \
        Tests/SheetMusicTests/MidiImporterFaçadeTests.swift
git commit -m "feat(midi): scaffold MidiImporter façade and pipeline types"
```

---

## Phase C — Track partition, bar segmentation, meta routing

### Task C1: `TrackPartitioner` (Pass 2)

**Files:**
- Create: `Sources/SheetMusicMIDI/Import/MidiImporter+Tracks.swift`
- Test: `Tests/SheetMusicTests/MidiImporterTracksTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterTracksTests {
    private func noteOn(_ tick: Int, channel: Int, pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(
            tick: tick, event: .noteOn(channel: channel, pitch: pitch, velocity: 80)
        )
    }
    private func noteOff(_ tick: Int, channel: Int, pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(
            tick: tick, event: .noteOff(channel: channel, pitch: pitch, velocity: 0)
        )
    }

    @Test func splitsMixedDrumAndPitchedIntoTwoTracks() {
        let track = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Mixed"))),
            noteOn(0, channel: 0, pitch: 60),
            noteOn(0, channel: 9, pitch: 36),
            noteOff(240, channel: 0, pitch: 60),
            noteOff(240, channel: 9, pitch: 36),
            TimedMidiEvent(tick: 240, event: .endOfTrack)
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track])
        let imports = MidiImporter.partition(file)
        #expect(imports.count == 2)
        #expect(imports.contains(where: { $0.isDrums && $0.trackName == "Mixed (drums)" }))
        #expect(imports.contains(where: { !$0.isDrums && $0.trackName == "Mixed" }))
    }

    @Test func skipsTracksWithOnlyMeta() {
        let metaOnly = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Tempo Map"))),
            TimedMidiEvent(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 500_000))),
            TimedMidiEvent(tick: 0, event: .endOfTrack)
        ])
        let withNotes = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Piano"))),
            noteOn(0, channel: 0, pitch: 60),
            noteOff(240, channel: 0, pitch: 60),
            TimedMidiEvent(tick: 240, event: .endOfTrack)
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [metaOnly, withNotes])
        let imports = MidiImporter.partition(file)
        #expect(imports.count == 1)
        #expect(imports[0].trackName == "Piano")
        #expect(imports[0].trackIndex == 1)
    }

    @Test func format0SplitsByChannel() {
        let track = MidiTrack(events: [
            noteOn(0, channel: 0, pitch: 60),
            noteOn(0, channel: 9, pitch: 36),
            noteOff(240, channel: 0, pitch: 60),
            noteOff(240, channel: 9, pitch: 36),
            TimedMidiEvent(tick: 240, event: .endOfTrack)
        ])
        let file = MidiFile(division: 480, format: 0, tracks: [track])
        let imports = MidiImporter.partition(file)
        #expect(imports.count == 2)
    }
}
```

- [ ] **Step 2: Run, expect failure**

```
swift test --filter MidiImporterTracksTests
```

- [ ] **Step 3: Implement partitioning**

`Sources/SheetMusicMIDI/Import/MidiImporter+Tracks.swift`:

```swift
import Foundation
import SheetMusicCore

extension MidiImporter {
    /// MIDI channel index used for GM percussion (0-based).
    static let drumChannel = 9

    static func partition(_ file: MidiFile) -> [ImportTrack] {
        var output: [ImportTrack] = []
        for (trackIndex, track) in file.tracks.enumerated() {
            let trackName = firstTrackName(in: track)
            let firstProgram = firstProgramChange(in: track)

            let drumEvents = track.events.filter { isOnChannel($0, channel: drumChannel) }
            let pitchedEvents = track.events.filter {
                !isOnChannel($0, channel: drumChannel) && hasNoteContent($0)
            }
            let drumNotes = drumEvents.contains(where: { hasNoteContent($0) })

            if !drumNotes && pitchedEvents.isEmpty {
                continue
            }

            if !pitchedEvents.isEmpty {
                output.append(ImportTrack(
                    trackIndex: trackIndex,
                    trackName: trackName,
                    isDrums: false,
                    programChange: firstProgram,
                    events: pitchedEvents + nonChannelEvents(track)
                ))
            }

            if drumNotes {
                let drumName = trackName.map {
                    pitchedEvents.isEmpty ? $0 : "\($0) (drums)"
                }
                output.append(ImportTrack(
                    trackIndex: trackIndex,
                    trackName: drumName,
                    isDrums: true,
                    programChange: nil,
                    events: drumEvents
                ))
            }
        }
        return output
    }

    private static func firstTrackName(in track: MidiTrack) -> String? {
        for ev in track.events {
            if case let .meta(.trackName(name)) = ev.event, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private static func firstProgramChange(in track: MidiTrack) -> Int? {
        for ev in track.events {
            if case let .programChange(_, program) = ev.event {
                return program
            }
        }
        return nil
    }

    private static func isOnChannel(_ ev: TimedMidiEvent, channel: Int) -> Bool {
        switch ev.event {
        case let .noteOn(c, _, _), let .noteOff(c, _, _),
             let .controlChange(c, _, _), let .programChange(c, _),
             let .pitchBend(c, _):
            return c == channel
        default:
            return false
        }
    }

    private static func hasNoteContent(_ ev: TimedMidiEvent) -> Bool {
        switch ev.event {
        case .noteOn, .noteOff: return true
        default: return false
        }
    }

    private static func nonChannelEvents(_ track: MidiTrack) -> [TimedMidiEvent] {
        // Channel-agnostic events (meta, endOfTrack) should ride along
        // with the pitched slice so trackName / endOfTrack survive.
        track.events.filter {
            switch $0.event {
            case .meta, .endOfTrack: return true
            default: return false
            }
        }
    }
}
```

- [ ] **Step 4: Run tests**

```
swift test --filter MidiImporterTracksTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter+Tracks.swift \
        Tests/SheetMusicTests/MidiImporterTracksTests.swift
git commit -m "feat(midi): track partitioner with drum/non-drum split"
```

### Task C2: `BarSegmenter` (Pass 4)

**Files:**
- Create: `Sources/SheetMusicMIDI/Import/MidiImporter+Meta.swift`
- Test: `Tests/SheetMusicTests/MidiImporterBarTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterBarTests {
    private func tn(_ name: String) -> TimedMidiEvent {
        TimedMidiEvent(tick: 0, event: .meta(.trackName(name)))
    }
    private func ts(_ tick: Int, _ n: Int, _ d: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .meta(.timeSignature(
            numerator: n, denominator: d, clocksPerClick: 24, thirtySecondsPerQuarter: 8
        )))
    }
    private func nOn(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOn(channel: 0, pitch: pitch, velocity: 80))
    }
    private func nOff(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOff(channel: 0, pitch: pitch, velocity: 0))
    }

    @Test func defaultsToFourFour() {
        let imports = [ImportTrack(
            trackIndex: 0, trackName: "P", isDrums: false,
            programChange: nil,
            events: [nOn(0, 60), nOff(1920, 60),
                     TimedMidiEvent(tick: 1920, event: .endOfTrack)]
        )]
        let measures = MidiImporter.segmentBars(imports: imports, division: 480)
        // 1920 ticks at 480 PPQ in 4/4 = 1 measure (1920 = 4*480)
        // The note ends exactly at the bar line, so 1 measure suffices.
        #expect(measures[0].count == 1)
        #expect(measures[0][0].timeSignature == TimeSignature(numerator: 4, denominator: 4))
    }

    @Test func splitsAtTimeSignatureChange() {
        let imports = [ImportTrack(
            trackIndex: 0, trackName: "P", isDrums: false,
            programChange: nil,
            events: [
                ts(0, 4, 4),
                nOn(0, 60), nOff(1920, 60),
                ts(1920, 3, 4),
                nOn(1920, 62), nOff(1920 + 1440, 62),
                TimedMidiEvent(tick: 1920 + 1440, event: .endOfTrack)
            ]
        )]
        let measures = MidiImporter.segmentBars(imports: imports, division: 480)
        // 1 measure of 4/4 + 1 measure of 3/4 = 2 measures
        #expect(measures[0].count == 2)
        #expect(measures[0][1].timeSignature == TimeSignature(numerator: 3, denominator: 4))
    }

    @Test func detectsCarryAcrossBars() {
        let imports = [ImportTrack(
            trackIndex: 0, trackName: "P", isDrums: false,
            programChange: nil,
            events: [
                nOn(0, 60), nOff(2400, 60),  // half + half + half across bars
                TimedMidiEvent(tick: 2400, event: .endOfTrack)
            ]
        )]
        let measures = MidiImporter.segmentBars(imports: imports, division: 480)
        #expect(measures[0].count >= 2)
        #expect(measures[0][0].carryOuts.count == 1)
        #expect(measures[0][1].carryIns.count == 1)
    }
}
```

- [ ] **Step 2: Run, expect failure**

```
swift test --filter MidiImporterBarTests
```

- [ ] **Step 3: Implement segmentation**

`Sources/SheetMusicMIDI/Import/MidiImporter+Meta.swift`:

```swift
import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Build a tick→measureIndex map and per-track per-measure
    /// `ImportMeasure` slices. Time-signature meta events from any
    /// ImportTrack contribute to the global map.
    static func segmentBars(
        imports: [ImportTrack],
        division: Int
    ) -> [[ImportMeasure]] {
        let timeline = buildBarTimeline(imports: imports, division: division)

        var output: [[ImportMeasure]] = []
        for track in imports {
            output.append(segment(track: track, timeline: timeline))
        }
        return output
    }

    /// Public for testing.
    static func buildBarTimeline(imports: [ImportTrack], division: Int) -> BarTimeline {
        // Collect all time-signature changes across every track.
        struct Change { var tick: Int; var sig: TimeSignature }
        var changes: [Change] = []
        for track in imports {
            for ev in track.events {
                if case let .meta(.timeSignature(n, d, _, _)) = ev.event {
                    changes.append(Change(tick: ev.tick, sig: TimeSignature(numerator: n, denominator: d)))
                }
            }
        }
        changes.sort { $0.tick < $1.tick }
        if changes.first?.tick != 0 {
            changes.insert(Change(tick: 0, sig: TimeSignature(numerator: 4, denominator: 4)), at: 0)
        }

        // Find the last tick produced by any track.
        let lastTick = imports.flatMap { $0.events }.map(\.tick).max() ?? 0

        var bars: [BarTimeline.Bar] = []
        var measureIndex = 0
        for (i, change) in changes.enumerated() {
            let segmentEnd = i + 1 < changes.count ? changes[i + 1].tick : lastTick
            let barTicks = barTicks(sig: change.sig, division: division)
            var t = change.tick
            while t < segmentEnd {
                bars.append(BarTimeline.Bar(
                    index: measureIndex,
                    startTick: t,
                    endTick: min(t + barTicks, segmentEnd),
                    timeSignature: change.sig
                ))
                measureIndex += 1
                t += barTicks
            }
            // If the segment ends short of a whole bar, still bump
            // measureIndex so subsequent ts changes start clean.
            if t < segmentEnd {
                bars.append(BarTimeline.Bar(
                    index: measureIndex,
                    startTick: t, endTick: segmentEnd,
                    timeSignature: change.sig
                ))
                measureIndex += 1
            }
        }

        if bars.isEmpty {
            // No notes, no ts changes: emit a single 4/4 bar.
            bars.append(BarTimeline.Bar(
                index: 0,
                startTick: 0,
                endTick: barTicks(sig: TimeSignature(numerator: 4, denominator: 4), division: division),
                timeSignature: TimeSignature(numerator: 4, denominator: 4)
            ))
        }
        return BarTimeline(bars: bars)
    }

    private static func barTicks(sig: TimeSignature, division: Int) -> Int {
        // beats per bar × ticks per beat
        // ticks per beat = division × (4 / denominator)
        (division * 4 * sig.numerator) / sig.denominator
    }

    private static func segment(
        track: ImportTrack, timeline: BarTimeline
    ) -> [ImportMeasure] {
        // Pair noteOn with noteOff (per channel/pitch) so we can
        // detect bar-crossing notes.
        struct OpenNote { var pitch: Int; var channel: Int; var onTick: Int }
        var open: [OpenNote] = []
        var pairs: [(on: Int, off: Int, pitch: Int, channel: Int)] = []
        for ev in track.events {
            switch ev.event {
            case let .noteOn(c, p, v) where v > 0:
                open.append(OpenNote(pitch: p, channel: c, onTick: ev.tick))
            case let .noteOn(c, p, _),
                 let .noteOff(c, p, _):
                if let idx = open.firstIndex(where: { $0.pitch == p && $0.channel == c }) {
                    let n = open.remove(at: idx)
                    pairs.append((on: n.onTick, off: ev.tick, pitch: p, channel: c))
                }
            default:
                break
            }
        }
        // Force-close anything still open at the last event tick.
        let lastTick = track.events.map(\.tick).max() ?? 0
        for n in open {
            pairs.append((on: n.onTick, off: lastTick, pitch: n.pitch, channel: n.channel))
        }

        var measures: [ImportMeasure] = []
        for bar in timeline.bars {
            var slice = ImportMeasure(
                startTick: bar.startTick,
                endTick: bar.endTick,
                measureIndex: bar.index,
                timeSignature: bar.timeSignature,
                events: track.events.filter { bar.startTick <= $0.tick && $0.tick < bar.endTick },
                carryIns: [],
                carryOuts: []
            )
            for p in pairs {
                let onBar = timeline.measureIndex(of: p.on)
                let offBar = timeline.measureIndex(of: max(p.off - 1, p.on))
                if onBar != offBar {
                    if onBar == bar.index {
                        slice.carryOuts.append(CarriedNote(
                            pitch: p.pitch, channel: p.channel,
                            sourceMeasureIndex: onBar,
                            noteOnTick: p.on, noteOffTick: p.off
                        ))
                    }
                    if onBar < bar.index && bar.index <= offBar {
                        slice.carryIns.append(CarriedNote(
                            pitch: p.pitch, channel: p.channel,
                            sourceMeasureIndex: onBar,
                            noteOnTick: p.on, noteOffTick: p.off
                        ))
                    }
                }
            }
            measures.append(slice)
        }
        return measures
    }
}

struct BarTimeline {
    struct Bar { var index: Int; var startTick: Int; var endTick: Int; var timeSignature: TimeSignature }
    var bars: [Bar]

    func measureIndex(of tick: Int) -> Int {
        for bar in bars where bar.startTick <= tick && tick < bar.endTick { return bar.index }
        return bars.last?.index ?? 0
    }
}
```

- [ ] **Step 4: Run tests**

```
swift test --filter MidiImporterBarTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter+Meta.swift \
        Tests/SheetMusicTests/MidiImporterBarTests.swift
git commit -m "feat(midi): bar segmenter with carry-in/out tracking"
```

---

## Phase D — Quantizer (Pass 5)

D' core. Five tasks build the quantizer up: binary fit, eighth triplet, multi-scale tuplets (the half-triplet half+quarter case), other ratios, and force-snap fallback.

### Task D1: Binary grid fit

**Files:**
- Create: `Sources/SheetMusicMIDI/Import/MidiImporter+Quantize.swift`
- Test: `Tests/SheetMusicTests/MidiImporterQuantizeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterQuantizeTests {
    private func nOn(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOn(channel: 0, pitch: pitch, velocity: 80))
    }
    private func nOff(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOff(channel: 0, pitch: pitch, velocity: 0))
    }

    @Test func straightSixteenthsFitBinary() {
        // 4 onsets at quarter intervals (0, 480, 960, 1440), bar 0..1920.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [nOn(0, 60), nOn(480, 62), nOn(960, 64), nOn(1440, 65),
                     nOff(1920, 65)],
            carryIns: [], carryOuts: []
        )
        let quantized = MidiImporter.quantize(
            measure: measure, division: 480, options: .init()
        )
        #expect(quantized.elements.count == 4)
        #expect(quantized.tuplets.isEmpty)
    }
}
```

- [ ] **Step 2: Run, expect failure**

```
swift test --filter MidiImporterQuantizeTests
```

- [ ] **Step 3: Implement minimal quantizer (binary only)**

`Sources/SheetMusicMIDI/Import/MidiImporter+Quantize.swift`:

```swift
import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Smallest tick that the binary grid will produce. Snapping
    /// rounds to the nearest multiple.
    static func quantize(
        measure: ImportMeasure,
        division: Int,
        options: MidiImportOptions
    ) -> QuantizedMeasure {
        let tolerance = options.onsetTolerance ?? max(division / 16, 1)
        let onsets = noteOnTicks(in: measure)
        let snapped = snapBinary(
            onsets: onsets,
            spanStart: measure.startTick,
            spanEnd: measure.endTick,
            grid: options.quantizeGrid.ticks(division: division),
            tolerance: tolerance
        )
        return buildQuantizedMeasure(
            measure: measure, snapped: snapped, tuplets: [], division: division
        )
    }

    static func noteOnTicks(in measure: ImportMeasure) -> [Int] {
        measure.events.compactMap { ev -> Int? in
            if case let .noteOn(_, _, v) = ev.event, v > 0 { return ev.tick }
            return nil
        }.sorted()
    }

    /// Round each onset to the nearest grid multiple (within
    /// tolerance). Onsets outside tolerance are still rounded — this
    /// keeps the quantizer total — but they incur no failure.
    static func snapBinary(
        onsets: [Int], spanStart: Int, spanEnd: Int,
        grid: Int, tolerance: Int
    ) -> [Int] {
        onsets.map { o in
            let offset = o - spanStart
            let nearest = ((offset + grid / 2) / grid) * grid
            return spanStart + nearest
        }
    }

    static func buildQuantizedMeasure(
        measure: ImportMeasure,
        snapped: [Int],
        tuplets: [(range: Range<Int>, ratio: TupletRatio)],
        division: Int
    ) -> QuantizedMeasure {
        // Pair each snapped onset with its event so we can build
        // chord groupings and gap rests.
        let onsetSet = Set(snapped)
        let allTicks = ([measure.startTick, measure.endTick] + snapped).sorted()

        var elements: [VoiceElement] = []
        var sustained: Set<Int> = []
        var prevTick = measure.startTick

        // For now: emit a single chord per unique snapped tick using
        // notes whose noteOn is at that tick. Voicing/tie generation
        // is Phase E; this stub produces a flat sequence so the test
        // can verify count matches.
        for tick in allTicks where tick > measure.startTick {
            let gap = tick - prevTick
            if gap > 0 {
                let duration = nearestDuration(ticks: gap, division: division)
                let pitches = noteOnPitches(at: prevTick, in: measure)
                let notes = pitches.map { Note(pitch: $0, tpc: 0) }
                elements.append(.chord(Chord(duration: duration, notes: ChordNotes(notes))))
            }
            prevTick = tick
        }
        return QuantizedMeasure(elements: elements, tuplets: [])
    }

    static func noteOnPitches(at tick: Int, in measure: ImportMeasure) -> [Int] {
        measure.events.compactMap { ev -> Int? in
            if case let .noteOn(_, p, v) = ev.event, v > 0, ev.tick == tick {
                return p
            }
            return nil
        }
    }

    /// Greedy nearest binary duration. Doesn't yet handle dotted /
    /// fractional remainders; later phases extend.
    static func nearestDuration(ticks: Int, division: Int) -> NoteDuration {
        let candidates: [NoteDuration] = [
            .whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond
        ]
        var best = NoteDuration.sixteenth
        var bestDelta = Int.max
        for c in candidates {
            let delta = abs(c.ticks(division: division) - ticks)
            if delta < bestDelta { bestDelta = delta; best = c }
        }
        return best
    }
}
```

- [ ] **Step 4: Run tests**

```
swift test --filter MidiImporterQuantizeTests
```

Expected: PASS for `straightSixteenthsFitBinary`. (Voicing not yet correct; we'll refine in Phase E.)

- [ ] **Step 5: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter+Quantize.swift \
        Tests/SheetMusicTests/MidiImporterQuantizeTests.swift
git commit -m "feat(midi): quantizer with binary grid fit"
```

### Task D2: Tuplet fit at beat scope (3:2 eighth-triplet)

**Files:**
- Modify: `Sources/SheetMusicMIDI/Import/MidiImporter+Quantize.swift`
- Modify: `Tests/SheetMusicTests/MidiImporterQuantizeTests.swift`

- [ ] **Step 1: Add a failing test for eighth triplet**

Append to `MidiImporterQuantizeTests`:

```swift
@Test func eighthTripletDetectedAtBeatScope() {
    // Triplet over beat 0..480: onsets at 0, 160, 320; offset at 480.
    let measure = ImportMeasure(
        startTick: 0, endTick: 480, measureIndex: 0,
        timeSignature: TimeSignature(numerator: 1, denominator: 4),
        events: [
            TimedMidiEvent(tick: 0,   event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
            TimedMidiEvent(tick: 160, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
            TimedMidiEvent(tick: 160, event: .noteOn(channel: 0, pitch: 62, velocity: 80)),
            TimedMidiEvent(tick: 320, event: .noteOff(channel: 0, pitch: 62, velocity: 0)),
            TimedMidiEvent(tick: 320, event: .noteOn(channel: 0, pitch: 64, velocity: 80)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 64, velocity: 0))
        ],
        carryIns: [], carryOuts: []
    )
    let quantized = MidiImporter.quantize(
        measure: measure, division: 480, options: .init()
    )
    #expect(quantized.tuplets.count == 1)
    #expect(quantized.tuplets[0].normalNotes == 2)
    #expect(quantized.tuplets[0].actualNotes == 3)
}
```

- [ ] **Step 2: Run, expect failure**

```
swift test --filter MidiImporterQuantizeTests
```

- [ ] **Step 3: Replace the quantizer body with a recursive span-driven version**

Replace `quantize(measure:division:options:)` and add helpers:

```swift
extension MidiImporter {
    static func quantize(
        measure: ImportMeasure,
        division: Int,
        options: MidiImportOptions
    ) -> QuantizedMeasure {
        let tolerance = options.onsetTolerance ?? max(division / 16, 1)
        let onsets = noteOnTicks(in: measure)
        let spans = candidateSpans(measure: measure, division: division)
        var assignments: [TupletAssignment] = []
        _ = fitSpanList(
            spans: spans,
            onsets: onsets,
            grid: options.quantizeGrid.ticks(division: division),
            tolerance: tolerance,
            tupletRatios: options.tupletRatios,
            assignments: &assignments
        )
        return assemble(
            measure: measure,
            assignments: assignments,
            division: division
        )
    }

    struct TupletAssignment {
        var range: Range<Int>           // tick range of the span
        var ratio: TupletRatio?         // nil → binary fit
        var grid: Int                   // tick step within the span
    }

    static func candidateSpans(measure: ImportMeasure, division: Int) -> [Range<Int>] {
        // Power-of-two splits anchored at measure.startTick. Yields
        // [whole measure, halves, quarters, half-beats]. Subdivisions
        // that don't divide cleanly into the time signature are
        // skipped (e.g. 3/4 has no clean half-measure split).
        var spans: [Range<Int>] = []
        let measureLen = measure.endTick - measure.startTick
        let beat = (division * 4) / measure.timeSignature.denominator
        let beats = measure.timeSignature.numerator
        let halfBeat = max(beat / 2, 1)

        for divisor in [1, 2, 4, beats, beats * 2] {
            if divisor < 1 { continue }
            if measureLen % divisor != 0 { continue }
            let span = measureLen / divisor
            if span < halfBeat { continue }
            for i in 0 ..< divisor {
                let start = measure.startTick + i * span
                spans.append(start ..< (start + span))
            }
        }
        // Dedupe while preserving order: prefer the largest spans
        // first so they get tried before their subdivisions.
        var seen: Set<Range<Int>> = []
        return spans.filter { seen.insert($0).inserted }
            .sorted { ($0.upperBound - $0.lowerBound) > ($1.upperBound - $1.lowerBound) }
    }

    /// Walk spans largest-first. For each, try to fit *all onsets
    /// inside that span* on a binary or tuplet grid. On success,
    /// record an assignment and remove the covered span from
    /// subsequent attempts. Onsets that no span successfully owns at
    /// the end fall through to a final force-snap.
    static func fitSpanList(
        spans: [Range<Int>],
        onsets: [Int],
        grid: Int,
        tolerance: Int,
        tupletRatios: [TupletRatio],
        assignments: inout [TupletAssignment]
    ) -> Bool {
        var covered: [Range<Int>] = []
        for span in spans {
            // Skip spans already inside a covered range.
            if covered.contains(where: { $0.contains(span.lowerBound) }) { continue }
            let inSpan = onsets.filter { span.contains($0) }
            if inSpan.isEmpty { continue }

            if fitsBinary(onsets: inSpan, span: span, grid: grid, tolerance: tolerance) {
                assignments.append(TupletAssignment(range: span, ratio: nil, grid: grid))
                covered.append(span)
                continue
            }
            if let ratio = tupletRatios.first(where: { ratio in
                fitsTuplet(onsets: inSpan, span: span, ratio: ratio, tolerance: tolerance)
            }) {
                let unit = (span.upperBound - span.lowerBound) / ratio.actual
                assignments.append(TupletAssignment(range: span, ratio: ratio, grid: unit))
                covered.append(span)
            }
        }
        return !assignments.isEmpty
    }

    static func fitsBinary(
        onsets: [Int], span: Range<Int>, grid: Int, tolerance: Int
    ) -> Bool {
        guard grid > 0 else { return false }
        return onsets.allSatisfy { onset in
            let offset = onset - span.lowerBound
            let mod = offset % grid
            return min(mod, grid - mod) <= tolerance
        }
    }

    static func fitsTuplet(
        onsets: [Int], span: Range<Int>, ratio: TupletRatio, tolerance: Int
    ) -> Bool {
        let unit = (span.upperBound - span.lowerBound) / ratio.actual
        guard unit > 0 else { return false }
        return onsets.allSatisfy { onset in
            let offset = onset - span.lowerBound
            let mod = offset % unit
            return min(mod, unit - mod) <= tolerance
        }
    }
}
```

- [ ] **Step 4: Replace `buildQuantizedMeasure` with `assemble`**

```swift
extension MidiImporter {
    static func assemble(
        measure: ImportMeasure,
        assignments: [TupletAssignment],
        division: Int
    ) -> QuantizedMeasure {
        // Walk the measure tick range, snapping each onset to its
        // owning assignment's grid, building a flat element list of
        // chords (notes from noteOn at the snapped tick). Tuplet
        // ranges convert to Tuplet values referencing element indices.
        let snappedOnsets = snap(
            onsets: noteOnTicks(in: measure),
            assignments: assignments,
            measure: measure,
            division: division
        )

        var elements: [VoiceElement] = []
        var tupletRanges: [(elementRange: ClosedRange<Int>, ratio: TupletRatio)] = []
        var prev = measure.startTick
        var inProgressTuplet: (TupletAssignment, startElement: Int)?

        let allTicks = (snappedOnsets.map(\.tick) + [measure.endTick]).sorted()
        for tick in allTicks where tick > prev {
            // Gap from prev to tick: rest if no notes carrying over.
            let gap = tick - prev
            let duration = durationFor(
                gap: gap, at: prev, assignments: assignments, division: division
            )
            let pitches = snappedOnsets.first(where: { $0.tick == prev })?.pitches ?? []
            let notes = ChordNotes(pitches.map { Note(pitch: $0, tpc: 0) })
            elements.append(.chord(Chord(duration: duration, notes: notes)))

            // Track tuplet element-range membership.
            if let owning = assignments.first(where: { $0.ratio != nil && $0.range.contains(prev) }),
               inProgressTuplet?.0.range != owning.range {
                if let in_progress = inProgressTuplet {
                    let r = in_progress.startElement ... (elements.count - 2)
                    tupletRanges.append((r, in_progress.0.ratio!))
                }
                inProgressTuplet = (owning, elements.count - 1)
            } else if assignments.first(where: { $0.range.contains(prev) })?.ratio == nil,
                      let in_progress = inProgressTuplet {
                let r = in_progress.startElement ... (elements.count - 2)
                tupletRanges.append((r, in_progress.0.ratio!))
                inProgressTuplet = nil
            }
            prev = tick
        }
        if let in_progress = inProgressTuplet {
            let r = in_progress.startElement ... (elements.count - 1)
            tupletRanges.append((r, in_progress.0.ratio!))
        }

        let tuplets = tupletRanges.map {
            Tuplet(
                normalNotes: $0.ratio.normal,
                actualNotes: $0.ratio.actual,
                startIndex: $0.elementRange.lowerBound,
                endIndex: $0.elementRange.upperBound
            )
        }
        return QuantizedMeasure(elements: elements, tuplets: tuplets)
    }

    static func snap(
        onsets: [Int],
        assignments: [TupletAssignment],
        measure: ImportMeasure,
        division: Int
    ) -> [(tick: Int, pitches: [Int])] {
        // For each unique original tick, pick the assignment that
        // contains it (largest matching) and round to its grid.
        var grouped: [Int: [Int]] = [:]
        for tick in onsets {
            let snapped = snapTick(tick, assignments: assignments)
            grouped[snapped, default: []].append(contentsOf: noteOnPitches(at: tick, in: measure))
        }
        return grouped.keys.sorted().map { (tick: $0, pitches: grouped[$0]!) }
    }

    static func snapTick(_ tick: Int, assignments: [TupletAssignment]) -> Int {
        guard let owning = assignments.first(where: { $0.range.contains(tick) }) else {
            return tick
        }
        let offset = tick - owning.range.lowerBound
        let nearest = ((offset + owning.grid / 2) / owning.grid) * owning.grid
        return owning.range.lowerBound + nearest
    }

    static func durationFor(
        gap: Int,
        at tick: Int,
        assignments: [TupletAssignment],
        division: Int
    ) -> NoteDuration {
        // Inside a tuplet, the *written* duration corresponds to
        // gap × actual / normal (the renderer scales it back).
        if let owning = assignments.first(where: { $0.ratio != nil && $0.range.contains(tick) }),
           let ratio = owning.ratio {
            let written = (gap * ratio.actual) / ratio.normal
            return nearestDuration(ticks: written, division: division)
        }
        return nearestDuration(ticks: gap, division: division)
    }
}
```

- [ ] **Step 5: Run tests**

```
swift test --filter MidiImporterQuantizeTests
```

Expected: both tests PASS. (`straightSixteenthsFitBinary` and `eighthTripletDetectedAtBeatScope`.)

- [ ] **Step 6: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter+Quantize.swift \
        Tests/SheetMusicTests/MidiImporterQuantizeTests.swift
git commit -m "feat(midi): tuplet fit with span-driven recursion"
```

### Task D3: Half-triplet with `half + quarter` members

**Files:**
- Modify: `Tests/SheetMusicTests/MidiImporterQuantizeTests.swift`

- [ ] **Step 1: Add the test from the spec's worked example**

```swift
@Test func halfTripletWithHalfPlusQuarterMembers() {
    // 4/4 measure (1920 ticks at 480 PPQ). Two notes: tick 0..1280
    // (= 2 tuplet-units, "half" written) and tick 1280..1920 (= 1
    // tuplet-unit, "quarter" written). Expected ratio (3,2).
    let measure = ImportMeasure(
        startTick: 0, endTick: 1920, measureIndex: 0,
        timeSignature: TimeSignature(numerator: 4, denominator: 4),
        events: [
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
            TimedMidiEvent(tick: 1280, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
            TimedMidiEvent(tick: 1280, event: .noteOn(channel: 0, pitch: 62, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 0, pitch: 62, velocity: 0))
        ],
        carryIns: [], carryOuts: []
    )
    let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
    #expect(q.tuplets.count == 1)
    #expect(q.tuplets[0].actualNotes == 3)
    #expect(q.tuplets[0].normalNotes == 2)
    // Two members, durations half + quarter.
    #expect(q.elements.count == 2)
    if case let .chord(c0) = q.elements[0] { #expect(c0.duration == .half) }
    if case let .chord(c1) = q.elements[1] { #expect(c1.duration == .quarter) }
}
```

- [ ] **Step 2: Run**

```
swift test --filter MidiImporterQuantizeTests
```

The test may already pass thanks to D2. If it fails, adjust `candidateSpans` to ensure the full-measure span is the first attempt.

- [ ] **Step 3: Inspect failure (if any) and adjust**

If the test fails, the most common cause is `candidateSpans` not emitting the full-measure span first. Verify by adding a temporary `print(spans)` in the test, then ensure `candidateSpans` always includes `measure.startTick ..< measure.endTick` as the first entry.

- [ ] **Step 4: Run tests until green**

```
swift test --filter MidiImporterQuantizeTests
```

- [ ] **Step 5: Commit**

```
git add Tests/SheetMusicTests/MidiImporterQuantizeTests.swift \
        Sources/SheetMusicMIDI/Import/MidiImporter+Quantize.swift
git commit -m "test(midi): half triplet with half+quarter members"
```

### Task D4: Quintuplet (5:4) and septuplet (7:4)

**Files:**
- Modify: `Tests/SheetMusicTests/MidiImporterQuantizeTests.swift`

- [ ] **Step 1: Add quintuplet and septuplet tests**

```swift
@Test func quintupletDetected() {
    // Five evenly-spaced onsets in one beat (480 ticks).
    let unit = 96 // 480 / 5
    let events: [TimedMidiEvent] = (0 ..< 5).flatMap { i -> [TimedMidiEvent] in
        let on  = TimedMidiEvent(tick: i * unit,
            event: .noteOn(channel: 0, pitch: 60 + i, velocity: 80))
        let off = TimedMidiEvent(tick: (i + 1) * unit,
            event: .noteOff(channel: 0, pitch: 60 + i, velocity: 0))
        return [on, off]
    }
    let measure = ImportMeasure(
        startTick: 0, endTick: 480, measureIndex: 0,
        timeSignature: TimeSignature(numerator: 1, denominator: 4),
        events: events, carryIns: [], carryOuts: []
    )
    let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
    #expect(q.tuplets.first?.actualNotes == 5)
    #expect(q.tuplets.first?.normalNotes == 4)
}

@Test func septupletDetected() {
    let unit = 480 / 7 // truncating; tolerance covers the rounding
    let events: [TimedMidiEvent] = (0 ..< 7).map { i in
        TimedMidiEvent(tick: i * unit,
            event: .noteOn(channel: 0, pitch: 60 + i, velocity: 80))
    }
    let measure = ImportMeasure(
        startTick: 0, endTick: 480, measureIndex: 0,
        timeSignature: TimeSignature(numerator: 1, denominator: 4),
        events: events
            + [TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 66, velocity: 0))],
        carryIns: [], carryOuts: []
    )
    let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
    #expect(q.tuplets.first?.actualNotes == 7)
    #expect(q.tuplets.first?.normalNotes == 4)
}
```

- [ ] **Step 2: Run and verify**

```
swift test --filter MidiImporterQuantizeTests
```

Expected: PASS thanks to D2's general implementation.

- [ ] **Step 3: Commit**

```
git add Tests/SheetMusicTests/MidiImporterQuantizeTests.swift
git commit -m "test(midi): quintuplet and septuplet detection"
```

### Task D5: Force-snap fallback when nothing fits

**Files:**
- Modify: `Sources/SheetMusicMIDI/Import/MidiImporter+Quantize.swift`
- Modify: `Tests/SheetMusicTests/MidiImporterQuantizeTests.swift`

- [ ] **Step 1: Add a test for unfit onsets**

```swift
@Test func unfitOnsetsForceSnapToGrid() {
    // Onsets far off any binary or tuplet grid in 4/4.
    let measure = ImportMeasure(
        startTick: 0, endTick: 1920, measureIndex: 0,
        timeSignature: TimeSignature(numerator: 4, denominator: 4),
        events: [
            TimedMidiEvent(tick: 0,    event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
            TimedMidiEvent(tick: 137,  event: .noteOn(channel: 0, pitch: 62, velocity: 80)),
            TimedMidiEvent(tick: 953,  event: .noteOn(channel: 0, pitch: 64, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 0, pitch: 64, velocity: 0))
        ],
        carryIns: [], carryOuts: []
    )
    // Should not throw, should produce 3 chords without crashing.
    let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
    #expect(q.elements.count >= 3)
}
```

- [ ] **Step 2: Run, verify or fix**

```
swift test --filter MidiImporterQuantizeTests
```

If failing: ensure `assemble` falls through cleanly when no assignment owns a tick. The `snapTick` helper already returns the original tick in that case; verify and adjust as needed.

- [ ] **Step 3: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter+Quantize.swift \
        Tests/SheetMusicTests/MidiImporterQuantizeTests.swift
git commit -m "test(midi): unfit onsets force-snap without throwing"
```

---

## Phase E — Voicing, ties, drums, glissando

### Task E1: Voicing with sustained-pitch tracking and within-bar ties

**Files:**
- Create: `Sources/SheetMusicMIDI/Import/MidiImporter+Voicing.swift`
- Test: `Tests/SheetMusicTests/MidiImporterVoicingTests.swift`

The existing `quantize` produces a flat element list. This task replaces its output with a properly voiced one that handles sustained pitches and ties within a bar.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterVoicingTests {
    private func nOn(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOn(channel: 0, pitch: pitch, velocity: 80))
    }
    private func nOff(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOff(channel: 0, pitch: pitch, velocity: 0))
    }

    @Test func simultaneousOnSimultaneousOffMakesOneChord() {
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [nOn(0, 60), nOn(0, 64), nOff(480, 60), nOff(480, 64)],
            carryIns: [], carryOuts: []
        )
        let voice = MidiImporter.voice(quantized: MidiImporter.quantize(
            measure: measure, division: 480, options: .init()
        ), measure: measure)
        #expect(voice.elements.count == 1)
        if case let .chord(c) = voice.elements[0] {
            #expect(c.notes.count == 2)
        }
    }

    @Test func staggeredOffMakesTieToContinuingPitch() {
        // C and E on at tick 0; E off at 240, C off at 480.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [nOn(0, 60), nOn(0, 64), nOff(240, 64), nOff(480, 60)],
            carryIns: [], carryOuts: []
        )
        let voice = MidiImporter.voice(quantized: MidiImporter.quantize(
            measure: measure, division: 480, options: .init()
        ), measure: measure)
        #expect(voice.elements.count == 2)
        // First chord: both pitches, C carries forward.
        if case let .chord(c0) = voice.elements[0] {
            let c = c0.notes.first(where: { $0.pitch == 60 })
            #expect(c?.tieForward == 1)
        }
        // Second chord: only C, with tieBack.
        if case let .chord(c1) = voice.elements[1] {
            #expect(c1.notes.count == 1)
            #expect(c1.notes.first?.tieBack == 1)
        }
    }
}
```

- [ ] **Step 2: Run, expect failure**

```
swift test --filter MidiImporterVoicingTests
```

- [ ] **Step 3: Implement voicing**

`Sources/SheetMusicMIDI/Import/MidiImporter+Voicing.swift`:

```swift
import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Produce a voice from a quantized measure plus the original
    /// ImportMeasure (which carries the noteOn/noteOff event stream
    /// needed to drive sustained-pitch tracking). The resulting Voice
    /// has tieBack/tieForward on continuing pitches within the bar.
    static func voice(
        quantized: QuantizedMeasure,
        measure: ImportMeasure
    ) -> Voice {
        // Collect (onTick, offTick, pitch) triples from the measure.
        struct Note { var onTick: Int; var offTick: Int; var pitch: Int }
        var open: [(channel: Int, pitch: Int, onTick: Int)] = []
        var notes: [Note] = []
        for ev in measure.events {
            switch ev.event {
            case let .noteOn(c, p, v) where v > 0:
                open.append((c, p, ev.tick))
            case let .noteOn(c, p, _),
                 let .noteOff(c, p, _):
                if let i = open.firstIndex(where: { $0.channel == c && $0.pitch == p }) {
                    let n = open.remove(at: i)
                    notes.append(Note(onTick: n.onTick, offTick: ev.tick, pitch: p))
                }
            default: break
            }
        }
        for n in open {
            notes.append(Note(onTick: n.onTick, offTick: measure.endTick, pitch: n.pitch))
        }

        // Walk grid positions = sorted union of onsets and offsets.
        let grid = Set(notes.flatMap { [$0.onTick, $0.offTick] })
            .union([measure.startTick, measure.endTick])
            .sorted()

        var elements: [VoiceElement] = []
        var sustained: [Int: Bool] = [:]   // pitch → pending tieBack
        var prev = measure.startTick

        for tick in grid where tick > prev {
            let active = notes.filter { $0.onTick <= prev && $0.offTick > prev }.map(\.pitch)
            let willContinue = notes.filter { $0.onTick <= prev && $0.offTick > tick }.map(\.pitch)
            let duration = nearestDuration(ticks: tick - prev, division: 480) // TODO: thread division
            let coreNotes: [SheetMusicCore.Note] = active.map { pitch in
                var n = SheetMusicCore.Note(pitch: pitch, tpc: 0)
                if sustained[pitch] == true { n.tieBack = 1 }
                if willContinue.contains(pitch) { n.tieForward = 1 }
                return n
            }
            elements.append(.chord(Chord(duration: duration, notes: ChordNotes(coreNotes))))
            sustained = Dictionary(uniqueKeysWithValues:
                willContinue.map { ($0, true) })
            prev = tick
        }

        // Re-attach tuplets from the quantized output. Element indices
        // produced here correspond 1:1 to grid steps; quantized.tuplets
        // already references grid positions by tick — so we translate.
        // For now, pass through quantized.tuplets shifted to our index
        // space: walk their tick ranges through the grid.
        let tuplets = quantized.tuplets
        return Voice(elements: elements, tuplets: tuplets)
    }
}
```

- [ ] **Step 4: Thread `division` through voicing**

The TODO above is a real issue — replace the hard-coded `480` with a parameter. Update the call sites accordingly:

```swift
static func voice(
    quantized: QuantizedMeasure,
    measure: ImportMeasure,
    division: Int
) -> Voice
```

and pass through where called.

- [ ] **Step 5: Run tests**

```
swift test --filter MidiImporterVoicingTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter+Voicing.swift \
        Tests/SheetMusicTests/MidiImporterVoicingTests.swift
git commit -m "feat(midi): single-voice voicing with sustained-pitch ties"
```

### Task E2: Cross-bar tie generation

**Files:**
- Modify: `Sources/SheetMusicMIDI/Import/MidiImporter+Voicing.swift`
- Modify: `Tests/SheetMusicTests/MidiImporterVoicingTests.swift`

- [ ] **Step 1: Add a failing cross-bar test**

```swift
@Test func crossBarNoteEmitsTieAcrossBar() {
    // Use a single-measure helper that injects carryIn/carryOut
    // records simulating the BarSegmenter's output.
    let m1 = ImportMeasure(
        startTick: 0, endTick: 1920, measureIndex: 0,
        timeSignature: TimeSignature(numerator: 4, denominator: 4),
        events: [nOn(0, 60), TimedMidiEvent(tick: 1920, event: .endOfTrack)],
        carryIns: [],
        carryOuts: [CarriedNote(
            pitch: 60, channel: 0, sourceMeasureIndex: 0,
            noteOnTick: 0, noteOffTick: 3000
        )]
    )
    let m2 = ImportMeasure(
        startTick: 1920, endTick: 3840, measureIndex: 1,
        timeSignature: TimeSignature(numerator: 4, denominator: 4),
        events: [nOff(3000, 60)],
        carryIns: [CarriedNote(
            pitch: 60, channel: 0, sourceMeasureIndex: 0,
            noteOnTick: 0, noteOffTick: 3000
        )],
        carryOuts: []
    )

    let v1 = MidiImporter.voice(
        quantized: MidiImporter.quantize(measure: m1, division: 480, options: .init()),
        measure: m1, division: 480
    )
    let v2 = MidiImporter.voice(
        quantized: MidiImporter.quantize(measure: m2, division: 480, options: .init()),
        measure: m2, division: 480
    )

    // Last chord of m1: tieForward set on pitch 60.
    if case let .chord(c) = v1.elements.last! {
        #expect(c.notes.first(where: { $0.pitch == 60 })?.tieForward == 1)
    }
    // First chord of m2: tieBack set on pitch 60.
    if case let .chord(c) = v2.elements.first! {
        #expect(c.notes.first(where: { $0.pitch == 60 })?.tieBack == 1)
    }
}
```

- [ ] **Step 2: Run, expect failure**

```
swift test --filter MidiImporterVoicingTests
```

- [ ] **Step 3: Extend voicing to honour `carryIns` / `carryOuts`**

Inside `voice(quantized:measure:division:)`, before the grid walk, synthesize a virtual `Note` for each `carryIn` (`onTick = measure.startTick`, `offTick = carryOff`) and for each `carryOut` (`onTick = original onTick`, `offTick = measure.endTick`). Tag each with a `tieBack` / `tieForward` flag respectively so the per-chord note builder can stamp the field. The simplest way:

```swift
struct VoiceNote { var onTick: Int; var offTick: Int; var pitch: Int
    var startsTied: Bool   // tieBack on first occurrence
    var endsTied: Bool     // tieForward on last occurrence
}
```

Replace the local `Note` struct above with `VoiceNote`, populate `startsTied = true` for carryIns and `endsTied = true` for carryOuts. When emitting a chord, set `tieBack` if the pitch's note was `startsTied` AND this is its first chord; set `tieForward` if it `endsTied` AND this is its last chord.

- [ ] **Step 4: Run tests**

```
swift test --filter MidiImporterVoicingTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter+Voicing.swift \
        Tests/SheetMusicTests/MidiImporterVoicingTests.swift
git commit -m "feat(midi): cross-bar tie generation via carryIn/carryOut"
```

### Task E3: Drum track headType mapping

**Files:**
- Modify: `Sources/SheetMusicMIDI/Import/MidiImporter+Voicing.swift`
- Test: `Tests/SheetMusicTests/MidiImporterDrumTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterDrumTests {
    @Test func drumTrackPopulatesHeadType() {
        // Pitch 35 = acoustic bass drum.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0,
                    event: .noteOn(channel: 9, pitch: 35, velocity: 80)),
                TimedMidiEvent(tick: 240,
                    event: .noteOff(channel: 9, pitch: 35, velocity: 0))
            ],
            carryIns: [], carryOuts: []
        )
        let voice = MidiImporter.voice(
            quantized: MidiImporter.quantize(
                measure: measure, division: 480, options: .init()
            ),
            measure: measure, division: 480, isDrumTrack: true
        )
        if case let .chord(c) = voice.elements[0] {
            #expect(c.notes.first?.headType != nil)
        }
    }
}
```

- [ ] **Step 2: Run, expect failure**

```
swift test --filter MidiImporterDrumTests
```

- [ ] **Step 3: Add `isDrumTrack` and a small GM head map**

In `MidiImporter+Voicing.swift`, extend `voice` with `isDrumTrack: Bool = false`. After building each `Note`, if `isDrumTrack`, look the pitch up in:

```swift
private static let gmDrumHeads: [Int: String] = [
    35: "normal", // acoustic bass drum
    36: "normal", // bass drum 1
    38: "normal", // acoustic snare
    40: "normal", // electric snare
    42: "cross",  // closed hi-hat
    44: "cross",  // pedal hi-hat
    46: "cross",  // open hi-hat
    49: "diamond", // crash cymbal 1
    51: "diamond", // ride cymbal 1
    57: "diamond", // crash cymbal 2
    59: "diamond"  // ride cymbal 2
]
```

(map name → set `note.headType = gmDrumHeads[pitch]`).

- [ ] **Step 4: Run, verify pass**

```
swift test --filter MidiImporterDrumTests
```

- [ ] **Step 5: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter+Voicing.swift \
        Tests/SheetMusicTests/MidiImporterDrumTests.swift
git commit -m "feat(midi): GM drum headType mapping for drum tracks"
```

### Task E4: Pitch-bend → Glissando detection

**Files:**
- Create: `Sources/SheetMusicMIDI/Import/MidiImporter+Pitchbend.swift`
- Test: `Tests/SheetMusicTests/MidiImporterGlissandoTests.swift`

- [ ] **Step 1: Write a round-trip test using the existing renderer**

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterGlissandoTests {
    @Test func roundTripsPortamentoFromRenderer() throws {
        // Build a tiny 2-note score with a glissando, render via
        // MidiRenderer, reimport via MidiImporter, and check that
        // the first note carries a Glissando.
        var note1 = Note(pitch: 60, tpc: 14)
        note1.glissando = Glissando(style: .portamento, visualType: .straight)
        let chord1 = Chord(duration: .quarter, notes: ChordNotes([note1]))
        let chord2 = Chord(duration: .quarter,
            notes: ChordNotes([Note(pitch: 64, tpc: 18)]))
        let voice = Voice(elements: [.chord(chord1), .chord(chord2)])
        let measure = Measure(voices: [voice])
        let staff = StaffContent(id: 1, measures: [measure])
        let part = Part(id: "P1", instrument: Instrument(id: "piano"))
        let score = Score(division: 480, parts: [part], staves: [staff])

        let smfBytes = try MidiWriter.write(MidiRenderer.render(score: score))
        let imported = try MidiImporter.parse(smfBytes)

        // Walk the imported score; expect a Glissando on the first
        // chord of the first voice.
        let firstVoice = imported.staves.first?.measures.first?.voices.first
        guard case let .chord(c)? = firstVoice?.elements.first else {
            Issue.record("no chord in imported score"); return
        }
        #expect(c.notes.first?.glissando != nil)
    }

    @Test func vibratoPitchBendIgnored() throws {
        // Ramp up and back to 0 within a held note → not monotonic.
        // Confirm no glissando is attached.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 60, event: .pitchBend(channel: 0, value: 9000)),
                TimedMidiEvent(tick: 120, event: .pitchBend(channel: 0, value: 8192)),
                TimedMidiEvent(tick: 180, event: .pitchBend(channel: 0, value: 7000)),
                TimedMidiEvent(tick: 240, event: .pitchBend(channel: 0, value: 8192)),
                TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 60, velocity: 0))
            ],
            carryIns: [], carryOuts: []
        )
        let attached = MidiImporter.detectGlissandos(
            measure: measure, voiceElements: [], division: 480
        )
        #expect(attached.isEmpty)
    }
}
```

- [ ] **Step 2: Run, expect failure**

```
swift test --filter MidiImporterGlissandoTests
```

- [ ] **Step 3: Implement narrow detection**

`Sources/SheetMusicMIDI/Import/MidiImporter+Pitchbend.swift`:

```swift
import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Mirror of `MidiRenderer+Glissando` write logic, run in
    /// reverse. Only attaches a Glissando when:
    ///  • the pitch-bend stream during a held note is monotonic,
    ///  • its final value lands within ±15 % of an integer semitone
    ///    (assuming a 12-semitone bend range), and
    ///  • the next note on the same channel pitches that integer
    ///    semitone away from the held note.
    /// All other pitch-bend usage (vibrato, expression bends, etc.)
    /// is silently dropped.
    static let detectGlissandoBendRangeSemitones = 12

    struct GlissandoAttachment: Equatable {
        var measureIndex: Int
        var elementIndex: Int
        var pitch: Int
        var glissando: Glissando
    }

    /// Public-test entry. In the real pipeline this is called by
    /// `assembleStaff` after voicing and gets element indices from
    /// the voiced output.
    static func detectGlissandos(
        measure: ImportMeasure,
        voiceElements: [VoiceElement],
        division: Int
    ) -> [GlissandoAttachment] {
        // Collect (channel, pitch, on, off) note ranges with their
        // pitch-bend streams.
        struct Span {
            var channel: Int; var pitch: Int
            var onTick: Int; var offTick: Int
            var bends: [Int]
        }
        var open: [(channel: Int, pitch: Int, onTick: Int, bends: [Int])] = []
        var spans: [Span] = []
        for ev in measure.events {
            switch ev.event {
            case let .noteOn(c, p, v) where v > 0:
                open.append((c, p, ev.tick, []))
            case let .noteOn(c, p, _), let .noteOff(c, p, _):
                if let i = open.firstIndex(where: { $0.channel == c && $0.pitch == p }) {
                    let n = open.remove(at: i)
                    spans.append(Span(channel: c, pitch: p,
                        onTick: n.onTick, offTick: ev.tick, bends: n.bends))
                }
            case let .pitchBend(c, value):
                for i in open.indices where open[i].channel == c {
                    open[i].bends.append(value)
                }
            default: break
            }
        }

        var attachments: [GlissandoAttachment] = []
        let semitoneStep = 8192 / detectGlissandoBendRangeSemitones // 682
        for span in spans where !span.bends.isEmpty {
            guard isMonotonic(span.bends) else { continue }
            let last = span.bends.last! - 8192   // -8192..8191 around 0
            // Approximate semitones (signed).
            let semitones = Int((Double(last) / Double(semitoneStep)).rounded())
            if semitones == 0 { continue }
            let target = span.pitch + semitones
            // Find the next noteOn on the same channel after this span.
            let next = measure.events.first(where: { ev in
                ev.tick >= span.offTick &&
                    (ev.event.isNoteOn(channel: span.channel) == true)
            })
            guard case let .noteOn(_, p, _)? = next?.event, p == target else { continue }

            // Within ±15 % of an integer semitone.
            let expected = Double(semitones * semitoneStep)
            let drift = abs(Double(last) - expected) / Double(semitoneStep)
            if drift > 0.15 { continue }

            // Element index lookup: find chord element starting at span.onTick.
            // (Assumes voicing produced a chord at that tick — true after
            //  Phase E1 voicing for a measure-internal noteOn.)
            attachments.append(GlissandoAttachment(
                measureIndex: measure.measureIndex,
                elementIndex: 0, // filled in by caller using span.onTick
                pitch: span.pitch,
                glissando: Glissando(style: .portamento, visualType: .straight)
            ))
        }
        return attachments
    }

    private static func isMonotonic(_ values: [Int]) -> Bool {
        guard values.count >= 2 else { return false }
        var increasing = 0, decreasing = 0
        for i in 1 ..< values.count {
            if values[i] > values[i - 1] { increasing += 1 }
            if values[i] < values[i - 1] { decreasing += 1 }
        }
        let total = values.count - 1
        let bias = max(increasing, decreasing)
        // Allow up to 5 % exceptions.
        return Double(total - bias) / Double(total) <= 0.05
    }
}

private extension MidiEvent {
    func isNoteOn(channel: Int) -> Bool {
        if case let .noteOn(c, _, v) = self, c == channel, v > 0 { return true }
        return false
    }
}
```

- [ ] **Step 4: Run tests; iterate until both pass**

```
swift test --filter MidiImporterGlissandoTests
```

The round-trip test depends on the full pipeline being wired (Phase F). If it fails because the importer still returns an empty Score, mark this test `.disabled("pending Phase F wiring")` and re-enable in Task F1's commit. The vibrato test should pass standalone.

- [ ] **Step 5: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter+Pitchbend.swift \
        Tests/SheetMusicTests/MidiImporterGlissandoTests.swift
git commit -m "feat(midi): narrow pitch-bend → glissando detection"
```

---

## Phase F — Swing, façade wiring, example app, round-trip golden

### Task F1: SwingAnalyzer (sync path)

**Files:**
- Create: `Sources/SheetMusicMIDI/Import/MidiImporter+Swing.swift`
- Test: `Tests/SheetMusicTests/MidiImporterSwingTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterSwingTests {
    @Test func resolverNotInvokedForStraight16ths() throws {
        var calls = 0
        var opts = MidiImportOptions()
        opts.resolveSwing = { _ in calls += 1; return .treatAsWritten }

        // Build a straight-16ths SMF: 1 measure, 16 onsets at evenly
        // spaced 30-tick intervals (480 ticks total).
        let bytes = try TestSMFs.straightSixteenthsBytes()
        _ = try MidiImporter.parse(bytes, options: opts)
        #expect(calls == 0)
    }

    @Test func resolverInvokedForSwungEighths() throws {
        var captured: SwingDetection?
        var opts = MidiImportOptions()
        opts.resolveSwing = { d in captured = d; return .treatAsWritten }

        let bytes = try TestSMFs.swungEighthsBytes(ratio: 2.0)
        _ = try MidiImporter.parse(bytes, options: opts)
        #expect(captured != nil)
        if let c = captured {
            #expect(c.estimatedRatio > 1.7)
            #expect(c.estimatedRatio < 2.3)
        }
    }
}

/// SMF byte builders for swing tests. Lives in test target only.
enum TestSMFs {
    static func straightSixteenthsBytes() throws -> Data {
        try ManualSMF.build(division: 480, format: 0,
            tracks: [ManualSMF.straightSixteenthsTrack()])
    }
    static func swungEighthsBytes(ratio: Double) throws -> Data {
        try ManualSMF.build(division: 480, format: 0,
            tracks: [ManualSMF.swungEighthsTrack(ratio: ratio)])
    }
}
```

(`ManualSMF` is defined in the next step.)

- [ ] **Step 2: Add a small SMF byte builder helper for tests**

`Tests/SheetMusicTests/Helpers/ManualSMF.swift`:

```swift
import Foundation
@testable import SheetMusicMIDI

enum ManualSMF {
    static func build(division: UInt16, format: UInt16, tracks: [Data]) throws -> Data {
        var data = Data()
        data.append(contentsOf: "MThd".utf8)
        data.append(contentsOf: [0, 0, 0, 6])
        data.append(UInt8(format >> 8)); data.append(UInt8(format & 0xFF))
        data.append(UInt8(tracks.count >> 8)); data.append(UInt8(tracks.count & 0xFF))
        data.append(UInt8(division >> 8)); data.append(UInt8(division & 0xFF))
        for body in tracks {
            data.append(contentsOf: "MTrk".utf8)
            let n = UInt32(body.count)
            data.append(contentsOf: [
                UInt8(n >> 24), UInt8((n >> 16) & 0xFF),
                UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)
            ])
            data.append(body)
        }
        return data
    }

    static func straightSixteenthsTrack() -> Data {
        var body = Data()
        // tick 0..480 = one beat, 4 sixteenths at 0/120/240/360.
        // Across 4 beats = 16 onsets, then EOT.
        let step: UInt8 = 120
        var firstDelta: UInt8 = 0
        for i in 0 ..< 16 {
            // delta
            body.append(i == 0 ? firstDelta : step)
            firstDelta = step
            body.append(0x90); body.append(60); body.append(80) // noteOn C
            body.append(0x00); body.append(0x80); body.append(60); body.append(0) // noteOff C, delta 0
        }
        body.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00])
        return body
    }

    static func swungEighthsTrack(ratio: Double) -> Data {
        // 4 beats, each with two eighths swung: front = 480 / (1+ratio),
        // back = front * ratio.
        var body = Data()
        let beat = 480
        let front = Int((Double(beat) / (1 + ratio)).rounded())
        let back = beat - front
        var lastTick = 0
        var first = true
        func deltaTo(_ tick: Int) -> [UInt8] {
            let d = tick - lastTick
            lastTick = tick
            return Array(VariableLengthQuantity.encode(d))
        }
        for beatIdx in 0 ..< 8 {
            let beatStart = beatIdx * beat
            // Front eighth on at beatStart, off at beatStart+front.
            body.append(contentsOf: deltaTo(beatStart))
            body.append(contentsOf: [0x90, 60, 80])
            body.append(contentsOf: deltaTo(beatStart + front))
            body.append(contentsOf: [0x80, 60, 0])
            // Back eighth on at beatStart+front, off at beatStart+beat.
            body.append(contentsOf: deltaTo(beatStart + front))
            body.append(contentsOf: [0x90, 62, 80])
            body.append(contentsOf: deltaTo(beatStart + beat))
            body.append(contentsOf: [0x80, 62, 0])
            first = false
        }
        body.append(contentsOf: deltaTo(lastTick))
        body.append(contentsOf: [0xFF, 0x2F, 0x00])
        return body
    }
}
```

- [ ] **Step 3: Implement SwingAnalyzer**

`Sources/SheetMusicMIDI/Import/MidiImporter+Swing.swift`:

```swift
import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Inspects each ImportTrack's note onsets for two-onsets-per-beat
    /// patterns and computes the average back/front ratio. Calls the
    /// provided resolver if confidence thresholds are met.
    static func analyzeSwing(
        track: ImportTrack,
        timeline: BarTimeline,
        division: Int,
        resolve: (SwingDetection) -> SwingResolution
    ) -> ImportTrack {
        let onsets = track.events.compactMap { ev -> Int? in
            if case let .noteOn(_, _, v) = ev.event, v > 0 { return ev.tick }
            return nil
        }
        guard onsets.count >= 16 else { return track }

        // Group onsets by beat and keep only beats with exactly two onsets.
        let beat = (division * 4) / 4 // assumes 4/4-style beat; refine if needed
        var ratios: [Double] = []
        var beatStart = 0
        let lastTick = onsets.last!
        while beatStart < lastTick {
            let beatEnd = beatStart + beat
            let inBeat = onsets.filter { $0 >= beatStart && $0 < beatEnd }
            if inBeat.count == 2 {
                let front = Double(inBeat[1] - inBeat[0])
                let back = Double(beatEnd - inBeat[1])
                if front > 0 { ratios.append(back / front) }
            }
            beatStart = beatEnd
        }
        guard ratios.count >= 8 else { return track }
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        let variance = ratios.map { pow($0 - mean, 2) }.reduce(0, +) / Double(ratios.count)
        let stddev = variance.squareRoot()
        guard mean >= 1.4 && mean <= 2.5 && stddev < 0.15 else { return track }

        let detection = SwingDetection(
            trackIndex: track.trackIndex,
            measureRange: 0 ..< (timeline.bars.last?.index ?? 0) + 1,
            estimatedRatio: mean,
            confidence: max(0, min(1, 1 - stddev / 0.2)),
            sampleSize: ratios.count
        )
        switch resolve(detection) {
        case .treatAsWritten: return track
        case .treatAsSwing:   return straighten(track: track, beat: beat)
        }
    }

    static func straighten(track: ImportTrack, beat: Int) -> ImportTrack {
        var copy = track
        for i in copy.events.indices {
            let tick = copy.events[i].tick
            let beatStart = (tick / beat) * beat
            let inBeatOffset = tick - beatStart
            // Snap inBeatOffset to nearest of 0 or beat/2.
            let snapped: Int
            if inBeatOffset < beat / 4 { snapped = 0 }
            else if inBeatOffset < (3 * beat) / 4 { snapped = beat / 2 }
            else { snapped = beat }
            copy.events[i] = TimedMidiEvent(tick: beatStart + snapped, event: copy.events[i].event)
        }
        // Re-sort in case snapping changed event order.
        copy.events.sort { $0.tick < $1.tick }
        return copy
    }
}
```

- [ ] **Step 4: Run tests**

```
swift test --filter MidiImporterSwingTests
```

These tests rely on `MidiImporter.parse(...)` running the full pipeline; the swing detection itself works in isolation but the resolver invocation requires Task F2 wiring. Mark them `.disabled("pending Phase F2 wiring")` if needed; re-enable in Task F2.

- [ ] **Step 5: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter+Swing.swift \
        Tests/SheetMusicTests/MidiImporterSwingTests.swift \
        Tests/SheetMusicTests/Helpers/ManualSMF.swift
git commit -m "feat(midi): statistical swing analyzer with resolver hook"
```

### Task F2: Wire the full pipeline into `assembleSync` and `assembleAsync`

**Files:**
- Modify: `Sources/SheetMusicMIDI/Import/MidiImporter.swift`
- Modify: prior tests with `.disabled` markers (re-enable)

- [ ] **Step 1: Promote `segment` to internal in `MidiImporter+Meta.swift`**

Change the per-track `segment(track:timeline:)` helper from `private` to `static`/internal so the façade can call it from `MidiImporter.swift`. (It is already a static helper inside `extension MidiImporter` in Phase C2 — just remove the `private` keyword.)

- [ ] **Step 2: Implement the real pipeline in `assembleSync`**

Replace the stub with:

```swift
static func assembleSync(
    file: MidiFile, options: MidiImportOptions, sourceFilename: String?
) throws -> Score {
    let imports = partition(file)
    let timeline = buildBarTimeline(imports: imports, division: file.division)
    let swung = imports.map { track -> ImportTrack in
        guard let resolve = options.resolveSwing else { return track }
        return analyzeSwing(track: track, timeline: timeline,
                            division: file.division, resolve: resolve)
    }
    return buildScore(
        file: file, imports: swung, timeline: timeline,
        options: options, sourceFilename: sourceFilename
    )
}

static func buildScore(
    file: MidiFile,
    imports: [ImportTrack],
    timeline: BarTimeline,
    options: MidiImportOptions,
    sourceFilename: String?
) -> Score {
    let perTrackMeasures = imports.map { segment(track: $0, timeline: timeline) }
    var parts: [Part] = []
    var staves: [StaffContent] = []
    for (trackIdx, measures) in perTrackMeasures.enumerated() {
        let track = imports[trackIdx]
        let voices = measures.map { m -> Voice in
            let q = quantize(measure: m, division: file.division, options: options)
            return voice(quantized: q, measure: m, division: file.division,
                         isDrumTrack: track.isDrums)
        }
        var scoreMeasures = voices.map { Measure(voices: [$0]) }
        if options.detectGlissando, !track.isDrums {
            attachGlissandos(
                measures: measures, voices: voices,
                into: &scoreMeasures, division: file.division
            )
        }
        let staffID = staves.count + 1
        var staff = StaffContent(id: staffID, measures: scoreMeasures)
        if staffID == 1 {
            injectMetaEvents(file: file, timeline: timeline, into: &staff)
        }
        staves.append(staff)
        parts.append(makePart(for: track))
    }
    let meta = resolveTitle(file: file, sourceFilename: sourceFilename)
    return Score(division: file.division,
        parts: parts, staves: staves, metaTags: meta)
}

static func attachGlissandos(
    measures: [ImportMeasure],
    voices: [Voice],
    into scoreMeasures: inout [Measure],
    division: Int
) {
    for (i, measure) in measures.enumerated() {
        let attachments = detectGlissandos(
            measure: measure, voiceElements: voices[i].elements,
            division: division
        )
        for att in attachments {
            // Find the chord whose first noteOn matches this attachment's
            // pitch + measure-relative onTick. The current `voice(...)`
            // emits chords at every grid tick, so we match by walking
            // the elements and checking notes contain att.pitch.
            guard var voice = scoreMeasures[i].voices.first else { continue }
            for (ei, element) in voice.elements.enumerated() {
                guard case var .chord(chord) = element,
                      var note = chord.notes.first(where: { $0.pitch == att.pitch })
                else { continue }
                note.glissando = att.glissando
                var notesArray = Array(chord.notes)
                if let idx = notesArray.firstIndex(where: { $0.pitch == att.pitch }) {
                    notesArray[idx] = note
                }
                chord.notes = ChordNotes(notesArray)
                voice.elements[ei] = .chord(chord)
                break
            }
            scoreMeasures[i].voices[0] = voice
        }
    }
}

static func injectMetaEvents(
    file: MidiFile, timeline: BarTimeline, into staff: inout StaffContent
) {
    let metas = file.tracks.flatMap(\.events).filter {
        if case .meta = $0.event { return true } else { return false }
    }
    for meta in metas {
        let measureIdx = timeline.measureIndex(of: meta.tick)
        guard measureIdx < staff.measures.count else { continue }
        let element: VoiceElement?
        switch meta.event {
        case let .meta(.tempo(micros)):
            // microsecondsPerQuarter → beatsPerSecond inversion.
            let bps = 1_000_000.0 / Double(micros)
            element = .tempo(Tempo(beatsPerSecond: bps))
        case let .meta(.timeSignature(n, d, _, _)):
            element = .timeSignature(TimeSignature(numerator: n, denominator: d))
        case let .meta(.keySignature(sf, _)):
            element = .keySignature(KeySignature(concertKey: sf))
        default:
            element = nil
        }
        if let el = element, var voice = staff.measures[measureIdx].voices.first {
            voice.elements.insert(el, at: 0)
            staff.measures[measureIdx].voices[0] = voice
        }
    }
}

static func makePart(for track: ImportTrack) -> Part {
    let instrument: Instrument
    if track.isDrums {
        instrument = Instrument(id: "drumset",
            longName: track.trackName ?? "Drumset",
            useDrumset: true,
            drumLineMap: [:])
    } else {
        instrument = Instrument(
            id: gmInstrumentID(for: track.programChange),
            longName: track.trackName ?? "Track"
        )
    }
    return Part(
        id: "P\(track.trackIndex)",
        trackName: track.trackName,
        instrument: instrument
    )
}

static func gmInstrumentID(for program: Int?) -> String {
    guard let p = program else { return "piano" }
    switch p {
    case 0...7: return "piano"
    case 24...31: return "guitar"
    case 32...39: return "bass"
    case 40...47: return "violin"
    case 56...63: return "trumpet"
    case 64...71: return "saxophone"
    case 72...79: return "flute"
    default: return "piano"
    }
}

static func resolveTitle(
    file: MidiFile, sourceFilename: String?
) -> [String: String] {
    var meta: [String: String] = [:]
    let track0 = file.tracks.first
    let track0HasNotes = track0?.events.contains {
        if case .noteOn = $0.event { return true } else { return false }
    } ?? false
    let track0Name = track0?.events.compactMap { ev -> String? in
        if case let .meta(.trackName(name)) = ev.event { return name }
        return nil
    }.first

    if file.format == 1, !track0HasNotes, let name = track0Name, !name.isEmpty {
        meta["workTitle"] = name
    } else if file.format == 0, let name = track0Name, !name.isEmpty {
        meta["workTitle"] = name
    } else if let filename = sourceFilename, !filename.isEmpty {
        meta["workTitle"] = filename
    }
    return meta
}
```

- [ ] **Step 3: Make `assembleAsync` honour `resolveSwingAsync`**

```swift
static func assembleAsync(
    file: MidiFile, options: MidiImportOptions, sourceFilename: String?
) async throws -> Score {
    if options.resolveSwingAsync == nil {
        return try assembleSync(file: file, options: options,
                                sourceFilename: sourceFilename)
    }
    let imports = partition(file)
    let timeline = buildBarTimeline(imports: imports, division: file.division)
    var swung: [ImportTrack] = []
    for track in imports {
        if let resolveAsync = options.resolveSwingAsync {
            let resolved = await asyncSwing(
                track: track, timeline: timeline,
                division: file.division, resolve: resolveAsync
            )
            swung.append(resolved)
        } else {
            swung.append(track)
        }
    }
    // Replicate the rest of assembleSync's body using swung + timeline.
    // Extract the non-swing portion of assembleSync into a helper to
    // share:
    return try buildScore(
        file: file, imports: swung, timeline: timeline,
        options: options, sourceFilename: sourceFilename
    )
}

static func asyncSwing(
    track: ImportTrack, timeline: BarTimeline, division: Int,
    resolve: @Sendable (SwingDetection) async -> SwingResolution
) async -> ImportTrack {
    // Same statistical pipeline as analyzeSwing, but await the resolver.
    let copy = track
    // Reuse analyzeSwing's body by extracting a `detectSwing` helper
    // returning Optional<SwingDetection>:
    guard let detection = detectSwing(track: copy, timeline: timeline,
                                      division: division)
    else { return copy }
    switch await resolve(detection) {
    case .treatAsWritten: return copy
    case .treatAsSwing:
        let beat = (division * 4) / 4
        return straighten(track: copy, beat: beat)
    }
}
```

Refactor `analyzeSwing` to extract the detection step (`detectSwing`) so both sync and async paths can share it.

- [ ] **Step 4: Re-enable disabled tests**

Remove `.disabled("pending Phase F1 wiring")` and `.disabled("pending Phase F2 wiring")` markers from `MidiImporterGlissandoTests` and `MidiImporterSwingTests`.

- [ ] **Step 5: Run all tests**

```
swift test
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```
git add Sources/SheetMusicMIDI/Import/MidiImporter.swift \
        Sources/SheetMusicMIDI/Import/MidiImporter+Meta.swift \
        Sources/SheetMusicMIDI/Import/MidiImporter+Swing.swift \
        Tests/SheetMusicTests/MidiImporterGlissandoTests.swift \
        Tests/SheetMusicTests/MidiImporterSwingTests.swift
git commit -m "feat(midi): wire full pipeline into MidiImporter façade"
```

### Task F3: SheetMusic façade entry points

**Files:**
- Modify: `Sources/SheetMusic/SheetMusic.swift`
- Test: `Tests/SheetMusicTests/SheetMusicFaçadeTests.swift` (extend if a similar suite exists; otherwise inline a few cases here)

- [ ] **Step 1: Write failing tests**

Add to (or create) the appropriate test file:

```swift
@Test func loadScoreFromMidiData() throws {
    let bytes = Data([
        0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
        0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
        0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x04,
        0x00, 0xFF, 0x2F, 0x00
    ])
    let score = try SheetMusic.loadScore(midiData: bytes)
    #expect(score.division == 480)
}

@Test func loadScoreFromMidiURLUsesFilenameAsTitle() throws {
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MyMidiSong.mid")
    let bytes = Data([
        0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
        0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
        0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x04,
        0x00, 0xFF, 0x2F, 0x00
    ])
    try bytes.write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    let score = try SheetMusic.loadScore(midiURL: tempURL)
    #expect(score.metaTags["workTitle"] == "MyMidiSong")
}
```

- [ ] **Step 2: Add the entry points**

Append to `Sources/SheetMusic/SheetMusic.swift` inside `extension SheetMusic`:

```swift
/// Parse SMF bytes (`.mid`) into a `Score`. Layout-related fields
/// default since MIDI carries no layout. Title falls back to
/// `sourceFilename` if no Track-Name meta is found.
public static func loadScore(
    midiData: Data,
    options: MidiImportOptions = .init(),
    sourceFilename: String? = nil
) throws -> Score {
    try MidiImporter.parse(midiData, options: options, sourceFilename: sourceFilename)
}

public static func loadScore(
    midiData: Data,
    options: MidiImportOptions,
    sourceFilename: String? = nil
) async throws -> Score {
    try await MidiImporter.parse(midiData, options: options, sourceFilename: sourceFilename)
}

/// Read an SMF file and parse into a `Score`. The filename (without
/// extension) is used as the title fallback when the SMF has no
/// Track-Name meta on Track 0.
public static func loadScore(
    midiURL: URL, options: MidiImportOptions = .init()
) throws -> Score {
    let data = try Data(contentsOf: midiURL)
    return try MidiImporter.parse(
        data, options: options,
        sourceFilename: midiURL.deletingPathExtension().lastPathComponent
    )
}

public static func loadScore(
    midiURL: URL, options: MidiImportOptions
) async throws -> Score {
    let data = try Data(contentsOf: midiURL)
    return try await MidiImporter.parse(
        data, options: options,
        sourceFilename: midiURL.deletingPathExtension().lastPathComponent
    )
}
```

- [ ] **Step 3: Run tests**

```
swift test
```

- [ ] **Step 4: Commit**

```
git add Sources/SheetMusic/SheetMusic.swift Tests/SheetMusicTests/...
git commit -m "feat(midi): add SheetMusic.loadScore midi entry points"
```

### Task F4: Example app integration

**Files:**
- Modify: `Example/SheetMusicExample/ScoreFileType.swift`
- Modify: `Example/SheetMusicExample/Shared/ScoreLoader.swift`

- [ ] **Step 1: Add `.midi` case**

In `ScoreFileType.swift`:

```swift
enum ScoreFileType {
    case mscx
    case mscz
    case musicXML
    case mxl
    case midi   // ← NEW

    static var allUTTypes: [UTType] {
        var out: [UTType] = []
        if let t = UTType(filenameExtension: "mscx") { out.append(t) }
        if let t = UTType(filenameExtension: "mscz") { out.append(t) }
        if let t = UTType(filenameExtension: "musicxml") { out.append(t) }
        if let t = UTType(filenameExtension: "mxl") { out.append(t) }
        out.append(.midi)              // ← NEW
        out.append(.xml)
        out.append(.zip)
        return out
    }

    static func detect(url: URL) -> ScoreFileType? {
        switch url.pathExtension.lowercased() {
        case "mscx": return .mscx
        case "mscz": return .mscz
        case "musicxml", "xml": return .musicXML
        case "mxl": return .mxl
        case "mid", "midi": return .midi   // ← NEW
        default: return nil
        }
    }
}
```

- [ ] **Step 2: Add the loader case**

In `ScoreLoader.swift`'s `load(from:)` switch:

```swift
case .midi:
    return try SheetMusic.loadScore(midiURL: url)
```

- [ ] **Step 3: Build the example app**

```
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           -skipPackagePluginValidation build
```

Expected: success.

- [ ] **Step 4: Commit**

```
git add Example/SheetMusicExample/ScoreFileType.swift \
        Example/SheetMusicExample/Shared/ScoreLoader.swift
git commit -m "feat(example): open .mid files via existing picker"
```

### Task F5: Round-trip golden test

**Files:**
- Create: `Tests/SheetMusicTests/MidiImportRoundTripTests.swift`

- [ ] **Step 1: Write the round-trip test**

```swift
import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite struct MidiImportRoundTripTests {
    /// For each enabled MidiExportTests case, exercise the round-trip:
    ///   mscx → render → SMF bytes → MidiImporter.parse → render →
    ///   compare to original SMF bytes via MidiSemanticComparison.
    @Test(arguments: [
        "Cmajor", "scale", "ChordSymbols", "ottava"
    ])
    func roundTrip(_ name: String) throws {
        let url = Bundle.module.url(forResource: name, withExtension: "mscx")!
        let mscxData = try Data(contentsOf: url)
        let original = try MSCXParser.parse(mscxData)
        let firstBytes = try MidiWriter.write(MidiRenderer.render(score: original))

        let imported = try MidiImporter.parse(firstBytes)
        let secondBytes = try MidiWriter.write(MidiRenderer.render(score: imported))

        try MidiSemanticComparison.expectEquivalent(
            produced: secondBytes, reference: firstBytes,
            tolerantOfTempomapNoise: true
        )
    }
}
```

The argument list starts conservative (4 cases). After F5 lands, gradually expand by removing `.disabled` markers per case, learning what fails and tightening the importer.

- [ ] **Step 2: Run**

```
swift test --filter MidiImportRoundTripTests
```

Expected: at least the simplest cases (`Cmajor`, `scale`) pass. Expect failures on more complex fixtures — record them as known limitations in a follow-up issue rather than blocking F5.

- [ ] **Step 3: Commit**

```
git add Tests/SheetMusicTests/MidiImportRoundTripTests.swift
git commit -m "test(midi): round-trip mscx → SMF → import → SMF golden"
```

---

## Final verification

- [ ] **Run the full suite**

```
swift test
swiftlint --quiet Sources Tests
```

Expected: all tests green; SwiftLint: 0 warnings, 0 errors.

- [ ] **Check the example app on iOS Simulator**

```
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           -skipPackagePluginValidation build
```

Boot a simulator, install, open a `.mid` file via the picker, confirm it renders.

- [ ] **Final commit (if anything stray)**

```
git status
git log --oneline -20
```

---

## Spec coverage check

- SMF Format 0/1, PPQ only — Task A1 (`MidiReader` rejects format 2 / SMPTE).
- Track→Part with drumset isolation — Task C1.
- Time-signature-driven barlining — Task C2.
- Single-voice + ties — Task E1, E2.
- D' quantize — Tasks D1–D5.
- Half-triplet half+quarter — Task D3 explicit test.
- Pitch-bend → Glissando narrow detection — Task E4.
- Statistical swing + sync/async resolvers — Tasks F1, F2.
- Tempo / key sig / time sig meta routing — Task F2 (`injectMetaEvents`).
- Title from Track 0 / filename fallback — Task F2 (`resolveTitle`).
- Example app integration — Task F4.
- Round-trip with `MidiRenderer` — Task F5.
- Errors permissive, only Format 2 / SMPTE / truncated MThd throw — Task A1 + A1 tests.
