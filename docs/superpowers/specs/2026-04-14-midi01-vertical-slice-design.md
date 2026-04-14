# Design: midi01 vertical slice — mscx → DOM → MIDI in Swift

Status: Approved (2026-04-14)
Scope: First milestone of a multi-phase port of MuseScore (C++) to Swift.

## 1. Goals & non-goals

### Goals
- Pass the `midi01` case from `MuseScore/src/importexport/midi/tests/midiexport_tests.cpp`, ported to Swift Testing.
- End-to-end pipeline: read `midi01.mscx` → typed Swift DOM → produce MIDI bytes → semantic-equivalence comparison against `midi01-ref.mid`.
- Set up a vertical-slice skeleton that future tests (midi02, midi03, …) can extend without restructuring.
- Idiomatic Swift: structs/enums, `throws`, no `class` unless required, Foundation only.

### Non-goals (this milestone)
- Other tests (midi02, Arpeggio, Bends, Volta, Swing, ornaments, lyrics, repeats, …) — explicitly deferred.
- Byte-exact comparison against reference `.mid` (deferred to a later milestone after semantic match works).
- `.mscz` (zipped) input.
- Layout, rendering for display, playback, Qt integration.
- `MasterScore::doLayout()` complexity (we do only the tick-counting that MIDI rendering depends on).

### Out of scope, will throw `unsupportedFeature`
For midi01, parser will throw on Spanner, Tuplet, Volta, Repeat barlines, Tie, Slur, Hairpin, Tempo text, Lyrics, GraceNotes, Arpeggio, Tremolo, Glissando, Ornament, Chord with multiple Notes (chords proper), Beam markup, Clef changes mid-measure, multi-Voice measures, multi-Staff parts.

## 2. Architecture

Single Swift Package target `MuseScoreParser`, organized into four cohesive layers under `Sources/MuseScoreParser/`. Dependencies are strictly top-down.

```
Sources/MuseScoreParser/
├── Score/      DOM types (pure value types)
├── Parsing/    .mscx XML → Score
├── Midi/       Score → in-memory MidiFile (event list)
├── IO/         MidiFile → Data (SMF format 1 bytes)
└── MuseScoreParser.swift   public entry points
```

Data flow:
```
.mscx Data
  → MSCXParser.parse(_:)            → Score
  → MidiRenderer.render(score:)     → MidiFile
  → MidiWriter.write(_:)            → Data
```

Renderer assigns ticks and channels internally (Score itself stays free of timing/channel state).

### Dependencies
- `Foundation` only (uses `XMLParser` SAX API).
- Drop `SwiftyXMLParser` from `Package.swift` (Foundation suffices, mscx voice content is order-sensitive heterogeneous which Codable XML libs handle awkwardly).
- Keep `ZIPFoundation` declared for future `.mscz` support (currently unused).

### Public API
```swift
public enum MuseScoreParser {
    public static func loadScore(mscxData: Data) throws -> Score
    public static func exportMIDI(score: Score) throws -> Data
}
```

### Errors
Single error enum; no Result types.
```swift
public enum MuseScoreParserError: Error {
    case invalidXML(underlying: Error)
    case malformedScore(reason: String)
    case unsupportedFeature(name: String, location: String?)
}
```

## 3. Score (Swift DOM)

All value types in `Sources/MuseScoreParser/Score/`. Names are idiomatic Swift; original C++ class noted in a doc comment when the rename is non-obvious. Score holds NO ticks, NO channels, NO computed layout — it is pure notation data.

```swift
// Score.swift  — C++: MasterScore / Score
public struct Score {
    public var division: Int                  // PPQ; <Division>
    public var parts: [Part]
    public var staves: [StaffContent]         // top-level <Staff id="N">
    public var metaTags: [String: String]
}

// Part.swift
public struct Part {
    public var id: String
    public var trackName: String?
    public var instrument: Instrument
    public var staffDeclarations: [StaffDeclaration]
}

// Instrument.swift
public struct Instrument {
    public var id: String
    public var longName: String?
    public var shortName: String?
    public var trackName: String?
    public var minPitchPlayable: Int?         // C++: minPitchP
    public var maxPitchPlayable: Int?         // C++: maxPitchP
    public var minPitchAmateur: Int?          // C++: minPitchA
    public var maxPitchAmateur: Int?          // C++: maxPitchA
    public var articulations: [InstrumentArticulation]
    public var channel: InstrumentChannel
}

// InstrumentArticulation.swift  — C++: MidiArticulation
public struct InstrumentArticulation {
    public var name: String?                  // nil = default
    public var velocity: Int                  // % of dynamic
    public var gateTime: Int                  // 1-100
}

// InstrumentChannel.swift  — C++: InstrChannel
public struct InstrumentChannel {
    public var name: String?
    public var program: Int = 0
    public var bank: Int = 0
    public var volume: Int = 100
    public var pan: Int = 64
    public var reverb: Int = 0
    public var chorus: Int = 0
}

// StaffDeclaration.swift  — Part-side declaration
public struct StaffDeclaration {
    public var staffType: String
    public var group: String
}

// StaffContent.swift  — top-level <Staff id="N">
public struct StaffContent {
    public var id: Int
    public var measures: [Measure]
}

// Measure.swift
public struct Measure {
    public var voices: [Voice]                // midi01: 1
}

// Voice.swift
public struct Voice {
    public var elements: [VoiceElement]       // ordered, heterogeneous
}

// VoiceElement.swift  — sum of in-voice element kinds
public enum VoiceElement {
    case chord(Chord)
    case rest(Rest)
    case keySignature(KeySignature)
    case timeSignature(TimeSignature)
}

// Chord.swift / Rest.swift  — C++: Chord / Rest (DurationElement)
public struct Chord {
    public var duration: NoteDuration
    public var notes: [Note]                  // midi01: 1
}
public struct Rest {
    public var duration: NoteDuration
}

// Note.swift
public struct Note {
    public var pitch: Int                     // MIDI 0..127
    public var tpc: Int                       // tonal pitch class
    public var accidental: Accidental?
}

public enum Accidental: String {
    case sharp, flat, natural, doubleSharp, doubleFlat
}

// NoteDuration.swift  — C++: TDuration (subset)
public enum NoteDuration {
    case whole, half, quarter, eighth, sixteenth, thirtySecond, sixtyFourth
    public func ticks(division: Int) -> Int   // whole = 4*division
}

// KeySignature.swift  — C++: KeySig
public struct KeySignature {
    public var concertKey: Int                // -7..+7
}

// TimeSignature.swift  — C++: TimeSig
public struct TimeSignature {
    public var numerator: Int
    public var denominator: Int
}

// Fraction.swift  — C++: Fraction
public struct Fraction: Hashable {
    public var numerator: Int
    public var denominator: Int
    // arithmetic + reduction; used by future durations
}
```

## 4. Parsing (mscx → Score)

`Sources/MuseScoreParser/Parsing/`. SAX-based DOM walker.

### Internal helper
`XMLNode`: a tiny order-preserving tree (name, attributes, text, children) built by an `XMLParserDelegate`. ~80 LOC.

```swift
struct XMLNode {
    let name: String
    let attributes: [String: String]
    var text: String                        // concatenated character data
    var children: [XMLNode]                 // order preserved

    func first(_ name: String) -> XMLNode?
    func all(_ name: String) -> [XMLNode]
}
enum XMLTreeParser {
    static func parse(_ data: Data) throws -> XMLNode  // returns root
}
```

### Decoding strategy
One file per type with a `static func decode(_ node: XMLNode) throws -> Self`. No generic Codable machinery — explicit, readable, and error messages can name the offending element.

```swift
extension Score {
    static func decode(_ root: XMLNode) throws -> Score   // root = <museScore>
}
extension Part      { static func decode(_:) throws -> Part }
extension Instrument{ static func decode(_:) throws -> Instrument }
// … one per type
```

### Voice element decoding (order-preserving)
Within `<voice>`, walk children in document order. For each child name, dispatch to the right decoder and append to `elements`. Unknown children → `unsupportedFeature`.

```swift
extension Voice {
    static func decode(_ node: XMLNode) throws -> Voice {
        var elements: [VoiceElement] = []
        for child in node.children {
            switch child.name {
            case "Chord":     elements.append(.chord(try Chord.decode(child)))
            case "Rest":      elements.append(.rest(try Rest.decode(child)))
            case "KeySig":    elements.append(.keySignature(try KeySignature.decode(child)))
            case "TimeSig":   elements.append(.timeSignature(try TimeSignature.decode(child)))
            default: throw MuseScoreParserError.unsupportedFeature(name: child.name, location: "Voice")
            }
        }
        return Voice(elements: elements)
    }
}
```

### Top-level shape
mscx root: `<museScore><Score>…</Score></museScore>`.
- `Score` contains zero or more `<Part>`, then zero or more `<Staff id="N">` (top-level staff content), plus `<Division>`, `<metaTag>`, `<Style>` (mostly ignored).
- `<Part>` contains nested `<Staff>` (declarations) and `<Instrument>`.
- `<Instrument>` contains `<Articulation>` (multiple), `<Channel>` (one+).

## 5. MIDI rendering (Score → MidiFile)

`Sources/MuseScoreParser/Midi/`.

### In-memory model
```swift
public struct MidiFile {
    public var division: Int               // PPQ
    public var format: Int = 1
    public var tracks: [MidiTrack]
}

public struct MidiTrack {
    public var events: [TimedMidiEvent]    // sorted by tick
}

public struct TimedMidiEvent {
    public var tick: Int
    public var event: MidiEvent
}

public enum MidiEvent {
    case noteOn(channel: Int, pitch: Int, velocity: Int)
    case noteOff(channel: Int, pitch: Int, velocity: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    case programChange(channel: Int, program: Int)
    case meta(MetaEvent)
    case endOfTrack
}

public enum MetaEvent {
    case trackName(String)
    case timeSignature(numerator: Int, denominator: Int, clocksPerClick: Int = 24, thirtySecondsPerQuarter: Int = 8)
    case keySignature(sharpsFlats: Int, isMinor: Bool = false)   // -7..+7
    case tempo(microsecondsPerQuarter: Int)
    case portChange(port: Int)
}
```

### Renderer
```swift
public enum MidiRenderer {
    public static func render(score: Score) throws -> MidiFile
}
```

Algorithm for midi01 scope:
1. Set `division = score.division`, `format = 1`.
2. Allocate one `MidiTrack` per `StaffContent`. Channel = staff index (0 for midi01).
3. For each track, prepend at tick 0 in this order (matching MuseScore's `writeHeader` + per-channel init in `exportmidi.cpp`):
   - Meta: track name (from Part.trackName or fallback to instrument longName)
   - Meta: time signature (initial)
   - Meta: key signature (initial; default C if none)
   - Meta: tempo (default 120 BPM = 500000 µs/quarter)
   - CC 121 (reset all controllers) = 0
   - RPN to set pitch bend range = 12 semitones: CC 101=0, CC 100=0, CC 6=12, CC 101=127, CC 100=127
   - Program change = instrument channel program
   - CC 7 (volume) = channel.volume
   - CC 10 (pan) = channel.pan
   - CC 91 (reverb) = channel.reverb
   - CC 93 (chorus) = channel.chorus
   - Meta: port change = 0
4. Walk voice elements assigning a running tick:
   - `KeySignature` / `TimeSignature` mid-measure: emit corresponding meta event at current tick, do not advance tick.
   - `Chord`: emit NoteOn(pitch, velocity=80) at tick for each note; emit NoteOff at tick + ticks(duration) − 1; advance tick by ticks(duration). Velocity comes from default articulation × default dynamic (mf=80) × instrument articulation gateTime applied to off time.
   - `Rest`: advance tick by ticks(duration), no events.
5. Append `endOfTrack` after last event.
6. Sort each track's events by `(tick, intra-tick-order)` where intra-tick order keeps MuseScore's deterministic insertion order (header items first, then notes).

Velocity for midi01: default dynamic value 80 (corresponds to "mf" baseline). Computed as `80 * defaultArticulation.velocity / 100` = 80 (since default is 100%).

Note duration ticks: `duration.ticks(division:) - 1` for the note-off, to avoid coinciding with the next note-on (matches reference `midi01-ref.mid` pattern of 479/1).

## 6. MIDI writer (MidiFile → Data)

`Sources/MuseScoreParser/IO/`.

### Helpers
```swift
enum VariableLengthQuantity {
    static func encode(_ value: Int) -> Data    // SMF VLQ, big-endian, 7-bit chunks
}

struct BinaryEncoder {
    var data: Data
    mutating func appendUInt8(_ v: UInt8)
    mutating func appendUInt16BE(_ v: UInt16)
    mutating func appendUInt32BE(_ v: UInt32)
    mutating func append(_ bytes: Data)
}
```

### `MidiWriter`
```swift
public enum MidiWriter {
    public static func write(_ file: MidiFile) throws -> Data
}
```

Output layout (SMF format 1):
- `MThd` chunk: 6 bytes payload: format (uint16), ntracks (uint16), division (uint16). Always 4D 54 68 64 / 00 00 00 06 / 00 01.
- For each track: `MTrk`, 4-byte length, then events as `<delta VLQ> <event bytes>`.
  - Running status NOT used (simpler, semantic comparison doesn't care; matches reference behavior loosely — note: ref uses running status for consecutive NoteOns. Semantic comparison strips this.)
- Each track terminated with `<delta 0> FF 2F 00`.

## 7. Tests (Swift Testing)

Replace XCTest skeleton in `Tests/MuseScoreParserTests/` with Swift Testing.

```swift
import Testing
@testable import MuseScoreParser

@Suite struct MidiExportTests {
    @Test func midi01() throws {
        let scoreURL = Bundle.module.url(forResource: "midi01", withExtension: "mscx")!
        let refURL   = Bundle.module.url(forResource: "midi01-ref", withExtension: "mid")!
        let score    = try MuseScoreParser.loadScore(mscxData: try Data(contentsOf: scoreURL))
        let produced = try MuseScoreParser.exportMIDI(score: score)
        let reference = try Data(contentsOf: refURL)
        try MidiSemanticComparison.assertEquivalent(produced: produced, reference: reference)
    }
}
```

### Resource bundling
`Package.swift` test target:
```swift
.testTarget(
    name: "MuseScoreParserTests",
    dependencies: ["MuseScoreParser"],
    resources: [.copy("Resources/midi01.mscx"),
                .copy("Resources/midi01-ref.mid")]
)
```
Files copied from `MuseScore/src/importexport/midi/tests/midiexport_data/` into `Tests/MuseScoreParserTests/Resources/` (committed copies — submodule path is fragile and SwiftPM can't reach into submodule sources).

### Semantic comparison
A small `MidiSemanticComparison` helper that:
1. Parses both byte streams into `[NormalizedTrackEvent]` per track.
2. `NormalizedTrackEvent` keeps `(tick, kind, channel, dataA, dataB)` for note/CC/program, and `(tick, metaKind, payload)` for meta.
3. Sort events at same tick by `(kind, channel, dataA)` so order quirks are normalized.
4. Allow note-off tick to differ by ±1 (covers the 479-vs-480 quirk).
5. `assertEquivalent` reports first divergence with both streams' surrounding context.

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Velocity mismatch (80 vs 100) | Hard-code default mf=80 for midi01. Document in `MidiRenderer` near where velocity is computed. |
| Initial channel-init CC ordering differs | Document required order (matches `exportmidi.cpp` exactly); semantic compare normalizes order at same tick. |
| Tick assignment off by one | Compare against ref byte trace during dev; keep a side-by-side debug dump utility (`MidiFile.debugDescription`). |
| Spec creep into midi02/03 | This milestone is midi01-only. Anything else throws `unsupportedFeature`. Future tests in separate spec docs. |
| File length lint (300 lines) | One type per file. Decoder extensions split into `MSCXDecoder+<Type>.swift`. |

## 9. Definition of done

- `swift test` runs the `midi01` Swift Testing case green on macOS.
- `Sources/MuseScoreParser/{Score,Parsing,Midi,IO}/` populated with the described files.
- No dead Swift files. `Sources/MuseScoreParser/Dummy.swift` removed.
- `Package.swift` updated (resources, dependencies trimmed).
- `MEMORY.md` references this spec.
- `git status` clean of unstaged changes; commit on green test (commit only when user requests).
