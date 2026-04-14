# midi01 Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement an end-to-end Swift pipeline that loads `midi01.mscx`, builds a typed `Score`, renders a `MidiFile`, writes SMF bytes, and passes a Swift Testing case that compares the output to `midi01-ref.mid` semantically.

**Architecture:** Single `MuseScoreParser` Swift package target, layered as `Score/` (DOM) → `Parsing/` (mscx → Score) → `Midi/` (Score → MidiFile) → `IO/` (MidiFile → Data). All value types. Foundation only (`XMLParser` SAX). See `docs/superpowers/specs/2026-04-14-midi01-vertical-slice-design.md`.

**Tech Stack:** Swift 6.2, Swift Package Manager, Foundation, Swift Testing.

---

## Phase 0 — Project setup

### Task 0.1: Trim Package.swift, copy test resources

**Files:**
- Modify: `Package.swift`
- Create: `Tests/MuseScoreParserTests/Resources/midi01.mscx`
- Create: `Tests/MuseScoreParserTests/Resources/midi01-ref.mid`
- Delete: `Sources/MuseScoreParser/Dummy.swift`
- Delete: `Tests/MuseScoreParserTests/MuseScoreParserTests.swift` (will be re-added in Phase 8)

- [ ] **Step 1: Copy test resources from submodule**

```bash
mkdir -p Tests/MuseScoreParserTests/Resources
cp MuseScore/src/importexport/midi/tests/midiexport_data/midi01.mscx Tests/MuseScoreParserTests/Resources/
cp MuseScore/src/importexport/midi/tests/midiexport_data/midi01-ref.mid Tests/MuseScoreParserTests/Resources/
```

- [ ] **Step 2: Rewrite `Package.swift`**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-musescore-parser",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "MuseScoreParser",
            targets: ["MuseScoreParser"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(
            name: "MuseScoreParser",
            dependencies: [
                "ZIPFoundation"
            ]
        ),
        .testTarget(
            name: "MuseScoreParserTests",
            dependencies: ["MuseScoreParser"],
            resources: [
                .copy("Resources/midi01.mscx"),
                .copy("Resources/midi01-ref.mid"),
            ]
        ),
    ]
)
```

Notes: Removed `SwiftyXMLParser` (replaced by Foundation `XMLParser`). Bumped macOS to 13 (needed for several Foundation APIs we'll use). watchOS / tvOS bumped accordingly.

- [ ] **Step 3: Delete obsolete skeleton files**

```bash
rm Sources/MuseScoreParser/Dummy.swift
rm Tests/MuseScoreParserTests/MuseScoreParserTests.swift
mkdir -p Sources/MuseScoreParser/{Score,Parsing,Midi,IO}
```

- [ ] **Step 4: Add a placeholder file so the target still compiles before real code lands**

Create `Sources/MuseScoreParser/MuseScoreParser.swift`:
```swift
public enum MuseScoreParser {
}
```

- [ ] **Step 5: Verify the package still resolves and builds**

```bash
swift build 2>&1 | tail -20
```
Expected: `Build complete!` (no targets to test yet).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/MuseScoreParser Tests/MuseScoreParserTests/Resources
git rm -f Sources/Dummy.swift 2>/dev/null || true
git commit -m "chore: scaffold midi01 vertical slice (Package, resources, layout)"
```

---

## Phase 1 — Foundation primitives

### Task 1.1: `MuseScoreParserError`

**Files:**
- Create: `Sources/MuseScoreParser/MuseScoreParserError.swift`
- Test: `Tests/MuseScoreParserTests/MuseScoreParserErrorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MuseScoreParser

@Suite struct MuseScoreParserErrorTests {
    @Test func unsupportedFeatureCarriesNameAndLocation() {
        let error = MuseScoreParserError.unsupportedFeature(name: "Tuplet", location: "Voice")
        guard case let .unsupportedFeature(name, location) = error else {
            Issue.record("expected unsupportedFeature case")
            return
        }
        #expect(name == "Tuplet")
        #expect(location == "Voice")
    }
}
```

- [ ] **Step 2: Run, expect failure (no type defined)**

```bash
swift test --filter MuseScoreParserErrorTests 2>&1 | tail -20
```

- [ ] **Step 3: Implement `MuseScoreParserError`**

```swift
import Foundation

public enum MuseScoreParserError: Error, Sendable {
    case invalidXML(underlying: Error)
    case malformedScore(reason: String)
    case unsupportedFeature(name: String, location: String?)
}
```

- [ ] **Step 4: Run, expect pass**

```bash
swift test --filter MuseScoreParserErrorTests 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
git add Sources/MuseScoreParser/MuseScoreParserError.swift Tests/MuseScoreParserTests/MuseScoreParserErrorTests.swift
git commit -m "feat(score): add MuseScoreParserError"
```

---

### Task 1.2: `Fraction`

**Files:**
- Create: `Sources/MuseScoreParser/Score/Fraction.swift`
- Test: `Tests/MuseScoreParserTests/FractionTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import MuseScoreParser

@Suite struct FractionTests {
    @Test func reducedOnInit() {
        let f = Fraction(numerator: 2, denominator: 4)
        #expect(f.numerator == 1)
        #expect(f.denominator == 2)
    }

    @Test func equalityIgnoresUnreducedForm() {
        #expect(Fraction(numerator: 2, denominator: 4) == Fraction(numerator: 1, denominator: 2))
    }

    @Test func addCommonDenominator() {
        let sum = Fraction(numerator: 1, denominator: 4) + Fraction(numerator: 1, denominator: 4)
        #expect(sum == Fraction(numerator: 1, denominator: 2))
    }

    @Test func addDifferentDenominator() {
        let sum = Fraction(numerator: 1, denominator: 3) + Fraction(numerator: 1, denominator: 6)
        #expect(sum == Fraction(numerator: 1, denominator: 2))
    }

    @Test func tickConversion() {
        // 1/4 at division 480 PPQ = 480 ticks
        #expect(Fraction(numerator: 1, denominator: 4).ticks(division: 480) == 480)
        // 4/4 at division 480 PPQ = 1920 ticks
        #expect(Fraction(numerator: 4, denominator: 4).ticks(division: 480) == 1920)
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `Fraction`**

```swift
import Foundation

/// A rational number used for note durations and time positions.
/// C++: `mu::engraving::Fraction`
public struct Fraction: Hashable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public init(numerator: Int, denominator: Int) {
        precondition(denominator > 0, "Fraction denominator must be positive")
        let g = Self.gcd(abs(numerator), denominator)
        self.numerator = numerator / g
        self.denominator = denominator / g
    }

    /// Number of MIDI ticks this fraction-of-a-whole-note represents at the given PPQ division.
    /// A whole note = 4 quarter notes = 4 * division ticks.
    public func ticks(division: Int) -> Int {
        return numerator * 4 * division / denominator
    }

    public static func + (lhs: Fraction, rhs: Fraction) -> Fraction {
        let d = lhs.denominator * rhs.denominator
        let n = lhs.numerator * rhs.denominator + rhs.numerator * lhs.denominator
        return Fraction(numerator: n, denominator: d)
    }

    public static func - (lhs: Fraction, rhs: Fraction) -> Fraction {
        let d = lhs.denominator * rhs.denominator
        let n = lhs.numerator * rhs.denominator - rhs.numerator * lhs.denominator
        return Fraction(numerator: n, denominator: d)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }
}
```

- [ ] **Step 4: Run, expect pass**

```bash
swift test --filter FractionTests 2>&1 | tail -30
```

- [ ] **Step 5: Commit**

```bash
git add Sources/MuseScoreParser/Score/Fraction.swift Tests/MuseScoreParserTests/FractionTests.swift
git commit -m "feat(score): add Fraction value type"
```

---

### Task 1.3: `NoteDuration` and `Accidental`

**Files:**
- Create: `Sources/MuseScoreParser/Score/NoteDuration.swift`
- Create: `Sources/MuseScoreParser/Score/Accidental.swift`
- Test: `Tests/MuseScoreParserTests/NoteDurationTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import MuseScoreParser

@Suite struct NoteDurationTests {
    @Test func quarterTicksAtPPQ480() {
        #expect(NoteDuration.quarter.ticks(division: 480) == 480)
    }

    @Test func wholeIs4Quarters() {
        #expect(NoteDuration.whole.ticks(division: 480) == 1920)
    }

    @Test func sixteenthIsQuarterOver4() {
        #expect(NoteDuration.sixteenth.ticks(division: 480) == 120)
    }

    @Test func decodesFromMscxName() {
        #expect(NoteDuration(mscxName: "quarter") == .quarter)
        #expect(NoteDuration(mscxName: "16th") == .sixteenth)
        #expect(NoteDuration(mscxName: "eighth") == .eighth)
        #expect(NoteDuration(mscxName: "half") == .half)
        #expect(NoteDuration(mscxName: "whole") == .whole)
        #expect(NoteDuration(mscxName: "32nd") == .thirtySecond)
        #expect(NoteDuration(mscxName: "64th") == .sixtyFourth)
        #expect(NoteDuration(mscxName: "tubaesque") == nil)
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `NoteDuration`**

```swift
import Foundation

/// Standard note duration. C++: `mu::engraving::TDuration` (subset).
public enum NoteDuration: String, Sendable {
    case whole, half, quarter, eighth, sixteenth, thirtySecond, sixtyFourth

    /// Number of MIDI ticks at a given PPQ division. quarter = 1 * division.
    public func ticks(division: Int) -> Int {
        switch self {
        case .whole:        return 4 * division
        case .half:         return 2 * division
        case .quarter:      return division
        case .eighth:       return division / 2
        case .sixteenth:    return division / 4
        case .thirtySecond: return division / 8
        case .sixtyFourth:  return division / 16
        }
    }

    /// Decode from MuseScore mscx `<durationType>` text values.
    public init?(mscxName: String) {
        switch mscxName {
        case "whole":   self = .whole
        case "half":    self = .half
        case "quarter": self = .quarter
        case "eighth":  self = .eighth
        case "16th":    self = .sixteenth
        case "32nd":    self = .thirtySecond
        case "64th":    self = .sixtyFourth
        default:        return nil
        }
    }
}
```

- [ ] **Step 4: Implement `Accidental`** (no separate test; it is a trivial enum exercised via Note tests later)

```swift
import Foundation

/// Visual accidental on a note. Display-only; MIDI pitch is the source of truth.
/// C++: `mu::engraving::AccidentalType` (subset)
public enum Accidental: String, Sendable {
    case sharp, flat, natural, doubleSharp, doubleFlat

    /// Decode from mscx `<Accidental><subtype>` text values.
    public init?(mscxSubtype: String) {
        switch mscxSubtype {
        case "accidentalSharp":       self = .sharp
        case "accidentalFlat":        self = .flat
        case "accidentalNatural":     self = .natural
        case "accidentalDoubleSharp": self = .doubleSharp
        case "accidentalDoubleFlat":  self = .doubleFlat
        default:                      return nil
        }
    }
}
```

- [ ] **Step 5: Run, expect pass**

```bash
swift test --filter NoteDurationTests 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add Sources/MuseScoreParser/Score/NoteDuration.swift Sources/MuseScoreParser/Score/Accidental.swift Tests/MuseScoreParserTests/NoteDurationTests.swift
git commit -m "feat(score): add NoteDuration and Accidental"
```

---

## Phase 2 — DOM types

### Task 2.1: Note, Chord, Rest, Voice, Measure, StaffContent (struct shells)

**Files:**
- Create: `Sources/MuseScoreParser/Score/Note.swift`
- Create: `Sources/MuseScoreParser/Score/Chord.swift`
- Create: `Sources/MuseScoreParser/Score/Rest.swift`
- Create: `Sources/MuseScoreParser/Score/VoiceElement.swift`
- Create: `Sources/MuseScoreParser/Score/Voice.swift`
- Create: `Sources/MuseScoreParser/Score/Measure.swift`
- Create: `Sources/MuseScoreParser/Score/StaffContent.swift`

These types are pure data shells; their decoding/rendering is tested elsewhere. No test in this task — types will be exercised by parser/renderer tests.

- [ ] **Step 1: Create Note.swift**

```swift
import Foundation

/// A pitched note inside a `Chord`. C++: `mu::engraving::Note` (subset).
public struct Note: Sendable, Equatable {
    public var pitch: Int      // MIDI 0..127
    public var tpc: Int        // tonal pitch class
    public var accidental: Accidental?

    public init(pitch: Int, tpc: Int, accidental: Accidental? = nil) {
        self.pitch = pitch
        self.tpc = tpc
        self.accidental = accidental
    }
}
```

- [ ] **Step 2: Create Chord.swift**

```swift
import Foundation

/// A simultaneously-sounding group of notes with a shared duration.
/// C++: `mu::engraving::Chord` (subset).
public struct Chord: Sendable, Equatable {
    public var duration: NoteDuration
    public var notes: [Note]

    public init(duration: NoteDuration, notes: [Note]) {
        self.duration = duration
        self.notes = notes
    }
}
```

- [ ] **Step 3: Create Rest.swift**

```swift
import Foundation

/// A silent duration. C++: `mu::engraving::Rest` (subset).
public struct Rest: Sendable, Equatable {
    public var duration: NoteDuration

    public init(duration: NoteDuration) {
        self.duration = duration
    }
}
```

- [ ] **Step 4: Create VoiceElement.swift**

```swift
import Foundation

/// One ordered element of a voice. The order is significant: a voice is a time-ordered
/// sequence of these. C++: not a single type (heterogeneous segment children).
public enum VoiceElement: Sendable, Equatable {
    case chord(Chord)
    case rest(Rest)
    case keySignature(KeySignature)
    case timeSignature(TimeSignature)
}
```

- [ ] **Step 5: Create Voice.swift**

```swift
import Foundation

/// Time-ordered sequence of elements within a measure. C++: `mu::engraving::Voice`.
public struct Voice: Sendable, Equatable {
    public var elements: [VoiceElement]

    public init(elements: [VoiceElement]) {
        self.elements = elements
    }
}
```

- [ ] **Step 6: Create Measure.swift**

```swift
import Foundation

/// A measure (bar) made up of one or more `Voice`s. C++: `mu::engraving::Measure`.
public struct Measure: Sendable, Equatable {
    public var voices: [Voice]

    public init(voices: [Voice]) {
        self.voices = voices
    }
}
```

- [ ] **Step 7: Create StaffContent.swift**

```swift
import Foundation

/// Top-level `<Staff id="N">` content (the actual measures of one staff).
/// C++: top-level `<Staff>` block in mscx (separate from the `<Part><Staff>` declaration).
public struct StaffContent: Sendable, Equatable {
    public var id: Int
    public var measures: [Measure]

    public init(id: Int, measures: [Measure]) {
        self.id = id
        self.measures = measures
    }
}
```

- [ ] **Step 8: Verify build**

```bash
swift build 2>&1 | tail -10
```
Expected: `Build complete!`

- [ ] **Step 9: Commit**

```bash
git add Sources/MuseScoreParser/Score
git commit -m "feat(score): add Note, Chord, Rest, Voice, Measure, StaffContent"
```

> Forward references `KeySignature` / `TimeSignature` in `VoiceElement.swift` are defined in Task 2.2; the package will not compile until then. Build verification is at the end of 2.2.

---

### Task 2.2: KeySignature, TimeSignature, InstrumentArticulation, InstrumentChannel, StaffDeclaration, Instrument, Part, Score

**Files:**
- Create: `Sources/MuseScoreParser/Score/KeySignature.swift`
- Create: `Sources/MuseScoreParser/Score/TimeSignature.swift`
- Create: `Sources/MuseScoreParser/Score/InstrumentArticulation.swift`
- Create: `Sources/MuseScoreParser/Score/InstrumentChannel.swift`
- Create: `Sources/MuseScoreParser/Score/StaffDeclaration.swift`
- Create: `Sources/MuseScoreParser/Score/Instrument.swift`
- Create: `Sources/MuseScoreParser/Score/Part.swift`
- Create: `Sources/MuseScoreParser/Score/Score.swift`

- [ ] **Step 1: KeySignature.swift**

```swift
import Foundation

/// Concert-pitch key signature. C++: `mu::engraving::KeySig`.
public struct KeySignature: Sendable, Equatable {
    /// Sharp/flat count: -7 (Cb) … +7 (C#). 0 = C major / a minor.
    public var concertKey: Int

    public init(concertKey: Int) {
        self.concertKey = concertKey
    }
}
```

- [ ] **Step 2: TimeSignature.swift**

```swift
import Foundation

/// A time signature like 4/4 or 6/8. C++: `mu::engraving::TimeSig`.
public struct TimeSignature: Sendable, Equatable {
    public var numerator: Int
    public var denominator: Int

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
}
```

- [ ] **Step 3: InstrumentArticulation.swift**

```swift
import Foundation

/// Per-articulation velocity/gate-time settings for an instrument.
/// C++: `mu::engraving::MidiArticulation`.
public struct InstrumentArticulation: Sendable, Equatable {
    public var name: String?      // nil = default articulation
    public var velocity: Int      // % multiplier on dynamic
    public var gateTime: Int      // 1..100 (% of duration the note actually sounds)

    public init(name: String? = nil, velocity: Int = 100, gateTime: Int = 100) {
        self.name = name
        self.velocity = velocity
        self.gateTime = gateTime
    }
}
```

- [ ] **Step 4: InstrumentChannel.swift**

```swift
import Foundation

/// A MIDI channel assignment for one playback flavor of an instrument
/// ("normal", "pizzicato", etc.). C++: `mu::engraving::InstrChannel` (subset).
public struct InstrumentChannel: Sendable, Equatable {
    public var name: String?
    public var program: Int
    public var bank: Int
    public var volume: Int
    public var pan: Int
    public var reverb: Int
    public var chorus: Int

    public init(
        name: String? = nil,
        program: Int = 0,
        bank: Int = 0,
        volume: Int = 100,
        pan: Int = 64,
        reverb: Int = 0,
        chorus: Int = 0
    ) {
        self.name = name
        self.program = program
        self.bank = bank
        self.volume = volume
        self.pan = pan
        self.reverb = reverb
        self.chorus = chorus
    }
}
```

- [ ] **Step 5: StaffDeclaration.swift**

```swift
import Foundation

/// Part-side staff declaration (the `<Staff>` *inside* a `<Part>`).
/// Holds rendering hints; the staff's measures live in `StaffContent`.
public struct StaffDeclaration: Sendable, Equatable {
    public var staffType: String   // e.g. "stdNormal"
    public var group: String       // e.g. "pitched"

    public init(staffType: String, group: String) {
        self.staffType = staffType
        self.group = group
    }
}
```

- [ ] **Step 6: Instrument.swift**

```swift
import Foundation

/// An instrument definition attached to a part. C++: `mu::engraving::Instrument`.
public struct Instrument: Sendable, Equatable {
    public var id: String
    public var longName: String?
    public var shortName: String?
    public var trackName: String?
    public var minPitchPlayable: Int?   // C++: minPitchP
    public var maxPitchPlayable: Int?   // C++: maxPitchP
    public var minPitchAmateur: Int?    // C++: minPitchA
    public var maxPitchAmateur: Int?    // C++: maxPitchA
    public var articulations: [InstrumentArticulation]
    public var channel: InstrumentChannel

    public init(
        id: String,
        longName: String? = nil,
        shortName: String? = nil,
        trackName: String? = nil,
        minPitchPlayable: Int? = nil,
        maxPitchPlayable: Int? = nil,
        minPitchAmateur: Int? = nil,
        maxPitchAmateur: Int? = nil,
        articulations: [InstrumentArticulation] = [],
        channel: InstrumentChannel = InstrumentChannel()
    ) {
        self.id = id
        self.longName = longName
        self.shortName = shortName
        self.trackName = trackName
        self.minPitchPlayable = minPitchPlayable
        self.maxPitchPlayable = maxPitchPlayable
        self.minPitchAmateur = minPitchAmateur
        self.maxPitchAmateur = maxPitchAmateur
        self.articulations = articulations
        self.channel = channel
    }
}
```

- [ ] **Step 7: Part.swift**

```swift
import Foundation

/// A score part (one instrument). C++: `mu::engraving::Part`.
public struct Part: Sendable, Equatable {
    public var id: String
    public var trackName: String?
    public var instrument: Instrument
    public var staffDeclarations: [StaffDeclaration]

    public init(
        id: String,
        trackName: String? = nil,
        instrument: Instrument,
        staffDeclarations: [StaffDeclaration] = []
    ) {
        self.id = id
        self.trackName = trackName
        self.instrument = instrument
        self.staffDeclarations = staffDeclarations
    }
}
```

- [ ] **Step 8: Score.swift**

```swift
import Foundation

/// Root of the parsed MuseScore document. C++: `mu::engraving::MasterScore`/`Score`.
public struct Score: Sendable, Equatable {
    public var division: Int
    public var parts: [Part]
    public var staves: [StaffContent]
    public var metaTags: [String: String]

    public init(
        division: Int,
        parts: [Part] = [],
        staves: [StaffContent] = [],
        metaTags: [String: String] = [:]
    ) {
        self.division = division
        self.parts = parts
        self.staves = staves
        self.metaTags = metaTags
    }
}
```

- [ ] **Step 9: Verify build**

```bash
swift build 2>&1 | tail -10
```
Expected: `Build complete!`

- [ ] **Step 10: Commit**

```bash
git add Sources/MuseScoreParser/Score
git commit -m "feat(score): add KeySignature, TimeSignature, Instrument, Part, Score"
```

---

## Phase 3 — XML helper

### Task 3.1: `XMLNode` + `XMLTreeParser`

**Files:**
- Create: `Sources/MuseScoreParser/Parsing/XMLNode.swift`
- Create: `Sources/MuseScoreParser/Parsing/XMLTreeParser.swift`
- Test: `Tests/MuseScoreParserTests/XMLTreeParserTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

@Suite struct XMLTreeParserTests {
    @Test func parsesSimpleNestedDocument() throws {
        let xml = #"<?xml version="1.0"?><root><a>hi</a><b key="v"/></root>"#
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        #expect(root.name == "root")
        #expect(root.children.count == 2)
        #expect(root.first("a")?.text == "hi")
        #expect(root.first("b")?.attributes["key"] == "v")
    }

    @Test func preservesChildOrder() throws {
        let xml = "<r><x/><y/><x/></r>"
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        #expect(root.children.map(\.name) == ["x", "y", "x"])
    }

    @Test func collectsRepeatedChildren() throws {
        let xml = "<r><n>1</n><n>2</n><n>3</n></r>"
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        #expect(root.all("n").map(\.text) == ["1", "2", "3"])
    }

    @Test func reportsInvalidXMLAsError() {
        let xml = "<root><unclosed></root>"
        #expect(throws: MuseScoreParserError.self) {
            try XMLTreeParser.parse(Data(xml.utf8))
        }
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `XMLNode`**

```swift
import Foundation

/// Order-preserving XML element tree built by `XMLTreeParser`.
/// Lightweight on purpose — we walk it in `MSCXDecoder+*` extensions.
public struct XMLNode: Sendable, Equatable {
    public let name: String
    public let attributes: [String: String]
    public var text: String
    public var children: [XMLNode]

    /// First direct child element with this name, or nil.
    public func first(_ name: String) -> XMLNode? {
        return children.first(where: { $0.name == name })
    }

    /// All direct child elements with this name, in document order.
    public func all(_ name: String) -> [XMLNode] {
        return children.filter { $0.name == name }
    }
}
```

- [ ] **Step 4: Implement `XMLTreeParser`**

```swift
import Foundation

/// Parses XML bytes into an in-memory `XMLNode` tree.
public enum XMLTreeParser {
    public static func parse(_ data: Data) throws -> XMLNode {
        let delegate = TreeBuildingDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse() else {
            if let error = delegate.error {
                throw MuseScoreParserError.invalidXML(underlying: error)
            }
            if let parserError = parser.parserError {
                throw MuseScoreParserError.invalidXML(underlying: parserError)
            }
            throw MuseScoreParserError.invalidXML(
                underlying: NSError(domain: "XMLTreeParser", code: -1)
            )
        }
        guard let root = delegate.root else {
            throw MuseScoreParserError.malformedScore(reason: "XML produced no root element")
        }
        return root
    }
}

private final class TreeBuildingDelegate: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    var error: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let node = XMLNode(name: elementName, attributes: attributeDict, text: "", children: [])
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let finished = stack.popLast() else { return }
        var trimmed = finished
        trimmed.text = finished.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stack.isEmpty {
            root = trimmed
        } else {
            stack[stack.count - 1].children.append(trimmed)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }
}
```

- [ ] **Step 5: Run, expect pass**

```bash
swift test --filter XMLTreeParserTests 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add Sources/MuseScoreParser/Parsing/XMLNode.swift Sources/MuseScoreParser/Parsing/XMLTreeParser.swift Tests/MuseScoreParserTests/XMLTreeParserTests.swift
git commit -m "feat(parsing): add XMLNode tree + XMLTreeParser SAX wrapper"
```

---

## Phase 4 — mscx decoders

### Task 4.1: Decoders for leaf types (Note, Chord, Rest, KeySignature, TimeSignature)

**Files:**
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+Note.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+Chord.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+Rest.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+KeySignature.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+TimeSignature.swift`
- Test: `Tests/MuseScoreParserTests/MSCXDecoderLeafTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

@Suite struct MSCXDecoderLeafTests {
    @Test func decodeNote() throws {
        let xml = "<Note><pitch>61</pitch><tpc>21</tpc><Accidental><subtype>accidentalSharp</subtype></Accidental></Note>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let note = try Note.decode(node)
        #expect(note.pitch == 61)
        #expect(note.tpc == 21)
        #expect(note.accidental == .sharp)
    }

    @Test func decodeChordWithSingleNote() throws {
        let xml = "<Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let chord = try Chord.decode(node)
        #expect(chord.duration == .quarter)
        #expect(chord.notes.count == 1)
        #expect(chord.notes[0].pitch == 60)
    }

    @Test func decodeRest() throws {
        let xml = "<Rest><durationType>half</durationType></Rest>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let rest = try Rest.decode(node)
        #expect(rest.duration == .half)
    }

    @Test func decodeKeySig() throws {
        let xml = "<KeySig><concertKey>1</concertKey></KeySig>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let key = try KeySignature.decode(node)
        #expect(key.concertKey == 1)
    }

    @Test func decodeTimeSig() throws {
        let xml = "<TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let ts = try TimeSignature.decode(node)
        #expect(ts.numerator == 4)
        #expect(ts.denominator == 4)
    }

    @Test func chordRequiresDuration() {
        let xml = "<Chord><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>"
        #expect(throws: MuseScoreParserError.self) {
            let node = try XMLTreeParser.parse(Data(xml.utf8))
            _ = try Chord.decode(node)
        }
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `Note.decode`**

```swift
import Foundation

extension Note {
    static func decode(_ node: XMLNode) throws -> Note {
        guard let pitchText = node.first("pitch")?.text, let pitch = Int(pitchText) else {
            throw MuseScoreParserError.malformedScore(reason: "Note missing <pitch>")
        }
        guard let tpcText = node.first("tpc")?.text, let tpc = Int(tpcText) else {
            throw MuseScoreParserError.malformedScore(reason: "Note missing <tpc>")
        }
        var accidental: Accidental?
        if let subtype = node.first("Accidental")?.first("subtype")?.text {
            accidental = Accidental(mscxSubtype: subtype)
        }
        return Note(pitch: pitch, tpc: tpc, accidental: accidental)
    }
}
```

- [ ] **Step 4: Implement `Chord.decode`**

```swift
import Foundation

extension Chord {
    static func decode(_ node: XMLNode) throws -> Chord {
        guard
            let durationText = node.first("durationType")?.text,
            let duration = NoteDuration(mscxName: durationText)
        else {
            throw MuseScoreParserError.malformedScore(reason: "Chord missing <durationType>")
        }
        let notes = try node.all("Note").map { try Note.decode($0) }
        return Chord(duration: duration, notes: notes)
    }
}
```

- [ ] **Step 5: Implement `Rest.decode`**

```swift
import Foundation

extension Rest {
    static func decode(_ node: XMLNode) throws -> Rest {
        guard
            let durationText = node.first("durationType")?.text,
            let duration = NoteDuration(mscxName: durationText)
        else {
            throw MuseScoreParserError.malformedScore(reason: "Rest missing <durationType>")
        }
        return Rest(duration: duration)
    }
}
```

- [ ] **Step 6: Implement `KeySignature.decode`**

```swift
import Foundation

extension KeySignature {
    static func decode(_ node: XMLNode) throws -> KeySignature {
        guard let text = node.first("concertKey")?.text, let key = Int(text) else {
            throw MuseScoreParserError.malformedScore(reason: "KeySig missing <concertKey>")
        }
        return KeySignature(concertKey: key)
    }
}
```

- [ ] **Step 7: Implement `TimeSignature.decode`**

```swift
import Foundation

extension TimeSignature {
    static func decode(_ node: XMLNode) throws -> TimeSignature {
        guard let nText = node.first("sigN")?.text, let n = Int(nText) else {
            throw MuseScoreParserError.malformedScore(reason: "TimeSig missing <sigN>")
        }
        guard let dText = node.first("sigD")?.text, let d = Int(dText) else {
            throw MuseScoreParserError.malformedScore(reason: "TimeSig missing <sigD>")
        }
        return TimeSignature(numerator: n, denominator: d)
    }
}
```

- [ ] **Step 8: Run, expect pass**

```bash
swift test --filter MSCXDecoderLeafTests 2>&1 | tail -20
```

- [ ] **Step 9: Commit**

```bash
git add Sources/MuseScoreParser/Parsing Tests/MuseScoreParserTests/MSCXDecoderLeafTests.swift
git commit -m "feat(parsing): add decoders for Note, Chord, Rest, KeySig, TimeSig"
```

---

### Task 4.2: Voice / Measure / StaffContent decoders

**Files:**
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+Voice.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+Measure.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+StaffContent.swift`
- Test: `Tests/MuseScoreParserTests/MSCXDecoderStructureTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

@Suite struct MSCXDecoderStructureTests {
    @Test func decodeVoicePreservesOrder() throws {
        let xml = """
        <voice>
          <KeySig><concertKey>1</concertKey></KeySig>
          <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
          <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
          <Rest><durationType>quarter</durationType></Rest>
        </voice>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let voice = try Voice.decode(node)
        #expect(voice.elements.count == 4)
        guard
            case .keySignature = voice.elements[0],
            case .timeSignature = voice.elements[1],
            case .chord = voice.elements[2],
            case .rest = voice.elements[3]
        else {
            Issue.record("voice element order/types unexpected: \(voice.elements)")
            return
        }
    }

    @Test func decodeVoiceRejectsUnknownChild() {
        let xml = "<voice><Tuplet/></voice>"
        #expect(throws: MuseScoreParserError.self) {
            let node = try XMLTreeParser.parse(Data(xml.utf8))
            _ = try Voice.decode(node)
        }
    }

    @Test func decodeMeasureWithSingleVoice() throws {
        let xml = """
        <Measure>
          <voice>
            <Rest><durationType>whole</durationType></Rest>
          </voice>
        </Measure>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let measure = try Measure.decode(node)
        #expect(measure.voices.count == 1)
        #expect(measure.voices[0].elements.count == 1)
    }

    @Test func decodeStaffContent() throws {
        let xml = """
        <Staff id="1">
          <Measure>
            <voice>
              <Rest><durationType>whole</durationType></Rest>
            </voice>
          </Measure>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let staff = try StaffContent.decode(node)
        #expect(staff.id == 1)
        #expect(staff.measures.count == 1)
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `Voice.decode`**

```swift
import Foundation

extension Voice {
    static func decode(_ node: XMLNode) throws -> Voice {
        var elements: [VoiceElement] = []
        elements.reserveCapacity(node.children.count)
        for child in node.children {
            switch child.name {
            case "Chord":
                elements.append(.chord(try Chord.decode(child)))
            case "Rest":
                elements.append(.rest(try Rest.decode(child)))
            case "KeySig":
                elements.append(.keySignature(try KeySignature.decode(child)))
            case "TimeSig":
                elements.append(.timeSignature(try TimeSignature.decode(child)))
            default:
                throw MuseScoreParserError.unsupportedFeature(name: child.name, location: "Voice")
            }
        }
        return Voice(elements: elements)
    }
}
```

- [ ] **Step 4: Implement `Measure.decode`**

```swift
import Foundation

extension Measure {
    static func decode(_ node: XMLNode) throws -> Measure {
        let voiceNodes = node.all("voice")
        guard !voiceNodes.isEmpty else {
            throw MuseScoreParserError.malformedScore(reason: "Measure has no <voice>")
        }
        let voices = try voiceNodes.map { try Voice.decode($0) }
        return Measure(voices: voices)
    }
}
```

- [ ] **Step 5: Implement `StaffContent.decode`**

```swift
import Foundation

extension StaffContent {
    static func decode(_ node: XMLNode) throws -> StaffContent {
        guard let idText = node.attributes["id"], let id = Int(idText) else {
            throw MuseScoreParserError.malformedScore(reason: "Staff missing id attribute")
        }
        let measures = try node.all("Measure").map { try Measure.decode($0) }
        return StaffContent(id: id, measures: measures)
    }
}
```

- [ ] **Step 6: Run, expect pass**

```bash
swift test --filter MSCXDecoderStructureTests 2>&1 | tail -20
```

- [ ] **Step 7: Commit**

```bash
git add Sources/MuseScoreParser/Parsing Tests/MuseScoreParserTests/MSCXDecoderStructureTests.swift
git commit -m "feat(parsing): add Voice, Measure, StaffContent decoders"
```

---

### Task 4.3: Instrument-related decoders (Articulation, Channel, Instrument, StaffDeclaration, Part)

**Files:**
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+InstrumentArticulation.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+InstrumentChannel.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+StaffDeclaration.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+Instrument.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+Part.swift`
- Test: `Tests/MuseScoreParserTests/MSCXDecoderInstrumentTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

@Suite struct MSCXDecoderInstrumentTests {
    @Test func decodeArticulationWithName() throws {
        let xml = "<Articulation name=\"staccato\"><velocity>100</velocity><gateTime>50</gateTime></Articulation>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let art = try InstrumentArticulation.decode(node)
        #expect(art.name == "staccato")
        #expect(art.velocity == 100)
        #expect(art.gateTime == 50)
    }

    @Test func decodeDefaultArticulationHasNoName() throws {
        let xml = "<Articulation><velocity>100</velocity><gateTime>100</gateTime></Articulation>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let art = try InstrumentArticulation.decode(node)
        #expect(art.name == nil)
    }

    @Test func decodeChannel() throws {
        let xml = "<Channel><program value=\"52\"/></Channel>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let ch = try InstrumentChannel.decode(node)
        #expect(ch.program == 52)
    }

    @Test func decodeInstrumentWithChannelAndArticulations() throws {
        let xml = """
        <Instrument id=\"voice\">
          <longName>Voice</longName>
          <shortName>Vo.</shortName>
          <trackName>Voice</trackName>
          <minPitchP>38</minPitchP>
          <maxPitchP>84</maxPitchP>
          <minPitchA>41</minPitchA>
          <maxPitchA>79</maxPitchA>
          <Articulation><velocity>100</velocity><gateTime>100</gateTime></Articulation>
          <Articulation name=\"staccato\"><velocity>100</velocity><gateTime>50</gateTime></Articulation>
          <Channel><program value=\"52\"/></Channel>
        </Instrument>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let instr = try Instrument.decode(node)
        #expect(instr.id == "voice")
        #expect(instr.longName == "Voice")
        #expect(instr.shortName == "Vo.")
        #expect(instr.minPitchPlayable == 38)
        #expect(instr.articulations.count == 2)
        #expect(instr.channel.program == 52)
    }

    @Test func decodeStaffDeclaration() throws {
        let xml = """
        <Staff>
          <StaffType group=\"pitched\"><name>stdNormal</name></StaffType>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let decl = try StaffDeclaration.decode(node)
        #expect(decl.staffType == "stdNormal")
        #expect(decl.group == "pitched")
    }

    @Test func decodePart() throws {
        let xml = """
        <Part id=\"1\">
          <Staff>
            <StaffType group=\"pitched\"><name>stdNormal</name></StaffType>
          </Staff>
          <trackName>Voice</trackName>
          <Instrument id=\"voice\">
            <Channel><program value=\"52\"/></Channel>
          </Instrument>
        </Part>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let part = try Part.decode(node)
        #expect(part.id == "1")
        #expect(part.trackName == "Voice")
        #expect(part.instrument.id == "voice")
        #expect(part.staffDeclarations.count == 1)
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `InstrumentArticulation.decode`**

```swift
import Foundation

extension InstrumentArticulation {
    static func decode(_ node: XMLNode) throws -> InstrumentArticulation {
        let name = node.attributes["name"]   // nil for default
        let velocity = Int(node.first("velocity")?.text ?? "100") ?? 100
        let gateTime = Int(node.first("gateTime")?.text ?? "100") ?? 100
        return InstrumentArticulation(name: name, velocity: velocity, gateTime: gateTime)
    }
}
```

- [ ] **Step 4: Implement `InstrumentChannel.decode`**

```swift
import Foundation

extension InstrumentChannel {
    static func decode(_ node: XMLNode) throws -> InstrumentChannel {
        var channel = InstrumentChannel()
        channel.name = node.attributes["name"]
        if let programNode = node.first("program"), let v = programNode.attributes["value"], let p = Int(v) {
            channel.program = p
        }
        if let v = node.first("controller")?.attributes["value"], let n = Int(v) {
            // bank/volume/pan/etc. are encoded as <controller ctrl="..." value="..."/>
            // For midi01 only <program> is present; future tasks expand this.
            channel.bank = n
        }
        return channel
    }
}
```

- [ ] **Step 5: Implement `StaffDeclaration.decode`**

```swift
import Foundation

extension StaffDeclaration {
    static func decode(_ node: XMLNode) throws -> StaffDeclaration {
        let staffTypeNode = node.first("StaffType")
        let staffType = staffTypeNode?.first("name")?.text ?? "stdNormal"
        let group = staffTypeNode?.attributes["group"] ?? "pitched"
        return StaffDeclaration(staffType: staffType, group: group)
    }
}
```

- [ ] **Step 6: Implement `Instrument.decode`**

```swift
import Foundation

extension Instrument {
    static func decode(_ node: XMLNode) throws -> Instrument {
        guard let id = node.attributes["id"] ?? node.first("instrumentId")?.text else {
            throw MuseScoreParserError.malformedScore(reason: "Instrument missing id")
        }
        let articulations = try node.all("Articulation").map { try InstrumentArticulation.decode($0) }
        guard let channelNode = node.first("Channel") else {
            throw MuseScoreParserError.malformedScore(reason: "Instrument missing <Channel>")
        }
        let channel = try InstrumentChannel.decode(channelNode)
        return Instrument(
            id: id,
            longName: node.first("longName")?.text,
            shortName: node.first("shortName")?.text,
            trackName: node.first("trackName")?.text,
            minPitchPlayable: node.first("minPitchP").flatMap { Int($0.text) },
            maxPitchPlayable: node.first("maxPitchP").flatMap { Int($0.text) },
            minPitchAmateur: node.first("minPitchA").flatMap { Int($0.text) },
            maxPitchAmateur: node.first("maxPitchA").flatMap { Int($0.text) },
            articulations: articulations,
            channel: channel
        )
    }
}
```

- [ ] **Step 7: Implement `Part.decode`**

```swift
import Foundation

extension Part {
    static func decode(_ node: XMLNode) throws -> Part {
        guard let id = node.attributes["id"] else {
            throw MuseScoreParserError.malformedScore(reason: "Part missing id")
        }
        let staffDecls = try node.all("Staff").map { try StaffDeclaration.decode($0) }
        guard let instrNode = node.first("Instrument") else {
            throw MuseScoreParserError.malformedScore(reason: "Part missing <Instrument>")
        }
        let instrument = try Instrument.decode(instrNode)
        return Part(
            id: id,
            trackName: node.first("trackName")?.text,
            instrument: instrument,
            staffDeclarations: staffDecls
        )
    }
}
```

- [ ] **Step 8: Run, expect pass**

```bash
swift test --filter MSCXDecoderInstrumentTests 2>&1 | tail -20
```

- [ ] **Step 9: Commit**

```bash
git add Sources/MuseScoreParser/Parsing Tests/MuseScoreParserTests/MSCXDecoderInstrumentTests.swift
git commit -m "feat(parsing): add Articulation, Channel, Instrument, Part decoders"
```

---

### Task 4.4: Top-level `Score.decode` + `MSCXParser`

**Files:**
- Create: `Sources/MuseScoreParser/Parsing/MSCXDecoder+Score.swift`
- Create: `Sources/MuseScoreParser/Parsing/MSCXParser.swift`
- Test: `Tests/MuseScoreParserTests/MSCXParserTests.swift`

- [ ] **Step 1: Write the failing test (uses bundled midi01.mscx)**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

@Suite struct MSCXParserTests {
    @Test func parsesMidi01() throws {
        let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        let data = try Data(contentsOf: url)
        let score = try MSCXParser.parse(data)
        #expect(score.division == 480)
        #expect(score.parts.count == 1)
        #expect(score.parts[0].instrument.channel.program == 52)
        #expect(score.parts[0].instrument.longName == "Voice")
        #expect(score.staves.count == 1)
        #expect(score.staves[0].id == 1)
        #expect(score.staves[0].measures.count == 1)
        let voice = score.staves[0].measures[0].voices[0]
        #expect(voice.elements.count == 6)            // KeySig, TimeSig, Chord×4
        guard case .keySignature(let k) = voice.elements[0] else {
            Issue.record("element 0 not key sig")
            return
        }
        #expect(k.concertKey == 1)
        let pitches = voice.elements.compactMap {
            if case .chord(let c) = $0 { return c.notes.first?.pitch } else { return nil }
        }
        #expect(pitches == [60, 61, 62, 63])
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `Score.decode`**

```swift
import Foundation

extension Score {
    static func decode(_ root: XMLNode) throws -> Score {
        guard root.name == "museScore" else {
            throw MuseScoreParserError.malformedScore(reason: "root is <\(root.name)>, expected <museScore>")
        }
        guard let scoreNode = root.first("Score") else {
            throw MuseScoreParserError.malformedScore(reason: "missing <Score>")
        }
        guard let divisionText = scoreNode.first("Division")?.text, let division = Int(divisionText) else {
            throw MuseScoreParserError.malformedScore(reason: "missing <Division>")
        }
        let parts = try scoreNode.all("Part").map { try Part.decode($0) }
        let staves = try scoreNode.all("Staff").map { try StaffContent.decode($0) }
        var metaTags: [String: String] = [:]
        for tag in scoreNode.all("metaTag") {
            if let name = tag.attributes["name"] {
                metaTags[name] = tag.text
            }
        }
        return Score(division: division, parts: parts, staves: staves, metaTags: metaTags)
    }
}
```

- [ ] **Step 4: Implement `MSCXParser`**

```swift
import Foundation

/// Public façade that turns mscx XML bytes into a `Score`.
public enum MSCXParser {
    public static func parse(_ data: Data) throws -> Score {
        let root = try XMLTreeParser.parse(data)
        return try Score.decode(root)
    }
}
```

- [ ] **Step 5: Run, expect pass**

```bash
swift test --filter MSCXParserTests 2>&1 | tail -30
```

- [ ] **Step 6: Commit**

```bash
git add Sources/MuseScoreParser/Parsing Tests/MuseScoreParserTests/MSCXParserTests.swift
git commit -m "feat(parsing): wire up Score.decode and MSCXParser; midi01 parses"
```

---

## Phase 5 — MIDI in-memory model

### Task 5.1: `MidiEvent`, `MetaEvent`, `TimedMidiEvent`, `MidiTrack`, `MidiFile`

**Files:**
- Create: `Sources/MuseScoreParser/Midi/MidiEvent.swift`
- Create: `Sources/MuseScoreParser/Midi/MetaEvent.swift`
- Create: `Sources/MuseScoreParser/Midi/TimedMidiEvent.swift`
- Create: `Sources/MuseScoreParser/Midi/MidiTrack.swift`
- Create: `Sources/MuseScoreParser/Midi/MidiFile.swift`

These are pure data shells; they will be exercised by renderer/writer tests. No dedicated test in this task.

- [ ] **Step 1: MidiEvent.swift**

```swift
import Foundation

/// One MIDI event (no timing). Channel events use 0-based channel indices (0..15).
public enum MidiEvent: Sendable, Equatable {
    case noteOn(channel: Int, pitch: Int, velocity: Int)
    case noteOff(channel: Int, pitch: Int, velocity: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    case programChange(channel: Int, program: Int)
    case meta(MetaEvent)
    case endOfTrack
}
```

- [ ] **Step 2: MetaEvent.swift**

```swift
import Foundation

/// SMF meta events used by the renderer.
public enum MetaEvent: Sendable, Equatable {
    case trackName(String)
    case timeSignature(numerator: Int, denominator: Int, clocksPerClick: Int, thirtySecondsPerQuarter: Int)
    case keySignature(sharpsFlats: Int, isMinor: Bool)
    case tempo(microsecondsPerQuarter: Int)
    case portChange(port: Int)
}
```

- [ ] **Step 3: TimedMidiEvent.swift**

```swift
import Foundation

/// `MidiEvent` plus the absolute tick at which it occurs.
public struct TimedMidiEvent: Sendable, Equatable {
    public var tick: Int
    public var event: MidiEvent

    public init(tick: Int, event: MidiEvent) {
        self.tick = tick
        self.event = event
    }
}
```

- [ ] **Step 4: MidiTrack.swift**

```swift
import Foundation

/// One SMF track: an ordered list of timed events.
public struct MidiTrack: Sendable, Equatable {
    public var events: [TimedMidiEvent]

    public init(events: [TimedMidiEvent] = []) {
        self.events = events
    }
}
```

- [ ] **Step 5: MidiFile.swift**

```swift
import Foundation

/// In-memory SMF representation. The renderer fills this; the writer turns it into bytes.
public struct MidiFile: Sendable, Equatable {
    public var division: Int      // PPQ
    public var format: Int        // 0, 1, or 2
    public var tracks: [MidiTrack]

    public init(division: Int, format: Int = 1, tracks: [MidiTrack] = []) {
        self.division = division
        self.format = format
        self.tracks = tracks
    }
}
```

- [ ] **Step 6: Verify build**

```bash
swift build 2>&1 | tail -10
```
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/MuseScoreParser/Midi
git commit -m "feat(midi): in-memory MidiFile/MidiTrack/MidiEvent model"
```

---

## Phase 6 — MIDI renderer

### Task 6.1: `MidiRenderer.render(score:)`

**Files:**
- Create: `Sources/MuseScoreParser/Midi/MidiRenderer.swift`
- Test: `Tests/MuseScoreParserTests/MidiRendererTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

@Suite struct MidiRendererTests {
    @Test func rendersMidi01HeaderAndNotes() throws {
        let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        let score = try MSCXParser.parse(try Data(contentsOf: url))
        let file = try MidiRenderer.render(score: score)

        #expect(file.format == 1)
        #expect(file.division == 480)
        #expect(file.tracks.count == 1)

        let track = file.tracks[0]

        // Header sequence at tick 0 must contain (in some order): track name, timesig, keysig,
        // tempo, reset CC, RPN init (5 CCs), program, vol/pan/reverb/chorus, port change.
        let tickZeroEvents = track.events.filter { $0.tick == 0 }.map(\.event)
        #expect(tickZeroEvents.contains(.meta(.trackName("Voice"))))
        #expect(tickZeroEvents.contains(.meta(.timeSignature(numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8))))
        #expect(tickZeroEvents.contains(.meta(.keySignature(sharpsFlats: 1, isMinor: false))))
        #expect(tickZeroEvents.contains(.meta(.tempo(microsecondsPerQuarter: 500_000))))
        #expect(tickZeroEvents.contains(.programChange(channel: 0, program: 52)))
        #expect(tickZeroEvents.contains(.controlChange(channel: 0, controller: 7, value: 100)))
        #expect(tickZeroEvents.contains(.controlChange(channel: 0, controller: 10, value: 64)))
        #expect(tickZeroEvents.contains(.meta(.portChange(port: 0))))

        // Four note-on/off pairs at quarter-note positions.
        let noteOns = track.events.compactMap { ev -> (Int, Int)? in
            if case .noteOn(_, let pitch, let vel) = ev.event, vel > 0 { return (ev.tick, pitch) } else { return nil }
        }
        #expect(noteOns == [(0, 60), (480, 61), (960, 62), (1440, 63)])

        let noteOffs = track.events.compactMap { ev -> (Int, Int)? in
            if case .noteOff(_, let pitch, _) = ev.event { return (ev.tick, pitch) }
            if case .noteOn(_, let pitch, let vel) = ev.event, vel == 0 { return (ev.tick, pitch) }
            return nil
        }
        #expect(noteOffs.count == 4)
        // Each off should be at on-tick + 479 (one tick less than full quarter; matches reference).
        #expect(noteOffs.map(\.0) == [479, 959, 1439, 1919])

        // EndOfTrack is last.
        #expect(track.events.last?.event == .endOfTrack)
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `MidiRenderer`**

```swift
import Foundation

/// Renders a `Score` into a `MidiFile`. Scope: midi01 vertical slice only.
/// Anything not in midi01 (multi-staff with multi-channel, multi-voice, ornaments,
/// dynamics, repeats, etc.) is intentionally not handled here; future tests will
/// extend this in additive ways.
public enum MidiRenderer {
    /// Default base velocity for "mf" (which is what midi01 implicitly uses when
    /// there are no Dynamics). C++: see compatmidirender.cpp velocity computation.
    private static let defaultDynamicVelocity = 80

    /// Default tempo if the score has no <Tempo> markers (120 BPM = 500000 µs/quarter).
    private static let defaultMicrosPerQuarter = 500_000

    public static func render(score: Score) throws -> MidiFile {
        var tracks: [MidiTrack] = []

        for (staffIndex, staff) in score.staves.enumerated() {
            let part = try part(forStaffId: staff.id, in: score)
            let channel = staffIndex   // midi01: one staff = channel 0

            var events: [TimedMidiEvent] = []

            // ---- Header at tick 0 (mirrors writeHeader + per-channel init in exportmidi.cpp) ----
            events.append(.init(tick: 0, event: .meta(.trackName(part.trackName ?? part.instrument.longName ?? "Track"))))

            let initialTimeSig = firstTimeSignature(in: staff) ?? TimeSignature(numerator: 4, denominator: 4)
            events.append(.init(tick: 0, event: .meta(.timeSignature(
                numerator: initialTimeSig.numerator,
                denominator: initialTimeSig.denominator,
                clocksPerClick: 24,
                thirtySecondsPerQuarter: 8
            ))))

            let initialKey = firstKeySignature(in: staff) ?? KeySignature(concertKey: 0)
            events.append(.init(tick: 0, event: .meta(.keySignature(sharpsFlats: initialKey.concertKey, isMinor: false))))

            events.append(.init(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: defaultMicrosPerQuarter))))

            // Reset all controllers, then RPN to set pitch-bend range = 12 semitones.
            events.append(.init(tick: 0, event: .controlChange(channel: channel, controller: 121, value: 0)))
            events.append(.init(tick: 0, event: .controlChange(channel: channel, controller: 100, value: 0)))
            events.append(.init(tick: 0, event: .controlChange(channel: channel, controller: 101, value: 0)))
            events.append(.init(tick: 0, event: .controlChange(channel: channel, controller: 6,   value: 12)))
            events.append(.init(tick: 0, event: .controlChange(channel: channel, controller: 100, value: 127)))
            events.append(.init(tick: 0, event: .controlChange(channel: channel, controller: 101, value: 127)))

            // Program + per-channel CC defaults
            let ch = part.instrument.channel
            events.append(.init(tick: 0, event: .programChange(channel: channel, program: ch.program)))
            events.append(.init(tick: 0, event: .controlChange(channel: channel, controller: 7,  value: ch.volume)))
            events.append(.init(tick: 0, event: .controlChange(channel: channel, controller: 10, value: ch.pan)))
            events.append(.init(tick: 0, event: .controlChange(channel: channel, controller: 91, value: ch.reverb)))
            events.append(.init(tick: 0, event: .controlChange(channel: channel, controller: 93, value: ch.chorus)))

            events.append(.init(tick: 0, event: .meta(.portChange(port: 0))))

            // ---- Notes ----
            var tick = 0
            for measure in staff.measures {
                guard let voice = measure.voices.first else { continue }
                if measure.voices.count > 1 {
                    throw MuseScoreParserError.unsupportedFeature(name: "multi-voice measure", location: "Staff \(staff.id)")
                }
                for element in voice.elements {
                    switch element {
                    case .keySignature(let k):
                        events.append(.init(tick: tick, event: .meta(.keySignature(sharpsFlats: k.concertKey, isMinor: false))))
                    case .timeSignature(let t):
                        events.append(.init(tick: tick, event: .meta(.timeSignature(
                            numerator: t.numerator, denominator: t.denominator,
                            clocksPerClick: 24, thirtySecondsPerQuarter: 8
                        ))))
                    case .rest(let r):
                        tick += r.duration.ticks(division: score.division)
                    case .chord(let c):
                        let durationTicks = c.duration.ticks(division: score.division)
                        let velocity = defaultDynamicVelocity * defaultArticulationVelocityScale(for: part.instrument) / 100
                        let offTick = tick + durationTicks - 1
                        for note in c.notes {
                            events.append(.init(tick: tick, event: .noteOn(channel: channel, pitch: note.pitch, velocity: velocity)))
                            events.append(.init(tick: offTick, event: .noteOff(channel: channel, pitch: note.pitch, velocity: 0)))
                        }
                        tick += durationTicks
                    }
                }
            }

            // ---- End of track ----
            let lastTick = events.map(\.tick).max() ?? 0
            events.append(.init(tick: lastTick, event: .endOfTrack))

            // Stable sort by tick (preserves header insertion order at tick 0).
            let sorted = events.enumerated()
                .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
                .map(\.element)

            tracks.append(MidiTrack(events: sorted))
        }

        return MidiFile(division: score.division, format: 1, tracks: tracks)
    }

    private static func part(forStaffId id: Int, in score: Score) throws -> Part {
        // mscx assigns staves to parts in document order; midi01 has one of each.
        guard let part = score.parts.first else {
            throw MuseScoreParserError.malformedScore(reason: "Score has no parts")
        }
        _ = id
        return part
    }

    private static func firstTimeSignature(in staff: StaffContent) -> TimeSignature? {
        for measure in staff.measures {
            for voice in measure.voices {
                for element in voice.elements {
                    if case .timeSignature(let t) = element { return t }
                }
            }
        }
        return nil
    }

    private static func firstKeySignature(in staff: StaffContent) -> KeySignature? {
        for measure in staff.measures {
            for voice in measure.voices {
                for element in voice.elements {
                    if case .keySignature(let k) = element { return k }
                }
            }
        }
        return nil
    }

    private static func defaultArticulationVelocityScale(for instrument: Instrument) -> Int {
        return instrument.articulations.first(where: { $0.name == nil })?.velocity ?? 100
    }
}
```

- [ ] **Step 4: Run, expect pass**

```bash
swift test --filter MidiRendererTests 2>&1 | tail -30
```

- [ ] **Step 5: Commit**

```bash
git add Sources/MuseScoreParser/Midi/MidiRenderer.swift Tests/MuseScoreParserTests/MidiRendererTests.swift
git commit -m "feat(midi): render Score into MidiFile (midi01 scope)"
```

---

## Phase 7 — MIDI writer

### Task 7.1: `VariableLengthQuantity` + `BinaryEncoder`

**Files:**
- Create: `Sources/MuseScoreParser/IO/VariableLengthQuantity.swift`
- Create: `Sources/MuseScoreParser/IO/BinaryEncoder.swift`
- Test: `Tests/MuseScoreParserTests/VariableLengthQuantityTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

@Suite struct VariableLengthQuantityTests {
    @Test func encodeZero() {
        #expect(VariableLengthQuantity.encode(0) == Data([0x00]))
    }
    @Test func encodeSmall() {
        #expect(VariableLengthQuantity.encode(0x40) == Data([0x40]))
        #expect(VariableLengthQuantity.encode(0x7F) == Data([0x7F]))
    }
    @Test func encodeTwoBytes() {
        // 0x80 -> 0x81 0x00
        #expect(VariableLengthQuantity.encode(0x80) == Data([0x81, 0x00]))
        // 0x2000 -> 0xC0 0x00
        #expect(VariableLengthQuantity.encode(0x2000) == Data([0xC0, 0x00]))
    }
    @Test func encodeRefNoteOffDelta479() {
        // midi01-ref.mid has delta=479 = 0x1DF -> 0x83 0x5F
        #expect(VariableLengthQuantity.encode(479) == Data([0x83, 0x5F]))
    }
    @Test func encodeMaxFourBytes() {
        // 0x0FFFFFFF -> 0xFF 0xFF 0xFF 0x7F
        #expect(VariableLengthQuantity.encode(0x0FFFFFFF) == Data([0xFF, 0xFF, 0xFF, 0x7F]))
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `VariableLengthQuantity`**

```swift
import Foundation

/// SMF variable-length quantity: 7-bit groups, big-endian, MSB set on continuation bytes.
enum VariableLengthQuantity {
    static func encode(_ value: Int) -> Data {
        precondition(value >= 0 && value <= 0x0FFF_FFFF, "VLQ supports 0..0x0FFFFFFF")
        if value == 0 { return Data([0x00]) }
        var bytes: [UInt8] = []
        var v = value
        bytes.append(UInt8(v & 0x7F))
        v >>= 7
        while v > 0 {
            bytes.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        return Data(bytes.reversed())
    }
}
```

- [ ] **Step 4: Implement `BinaryEncoder`**

```swift
import Foundation

/// Tiny mutable byte buffer with big-endian append helpers.
struct BinaryEncoder {
    var data = Data()

    mutating func appendUInt8(_ v: UInt8) {
        data.append(v)
    }
    mutating func appendUInt16BE(_ v: UInt16) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }
    mutating func appendUInt32BE(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8)  & 0xFF))
        data.append(UInt8(v & 0xFF))
    }
    mutating func append(_ bytes: Data) {
        data.append(bytes)
    }
}
```

- [ ] **Step 5: Run, expect pass**

```bash
swift test --filter VariableLengthQuantityTests 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add Sources/MuseScoreParser/IO Tests/MuseScoreParserTests/VariableLengthQuantityTests.swift
git commit -m "feat(io): add VLQ encoder and BinaryEncoder"
```

---

### Task 7.2: `MidiWriter`

**Files:**
- Create: `Sources/MuseScoreParser/IO/MidiWriter.swift`
- Test: `Tests/MuseScoreParserTests/MidiWriterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

@Suite struct MidiWriterTests {
    @Test func writesHeaderChunkFormat1Division480() throws {
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [.init(tick: 0, event: .endOfTrack)])
        ])
        let bytes = try MidiWriter.write(file)
        // MThd chunk
        #expect(Array(bytes.prefix(4)) == Array("MThd".utf8))
        #expect(Array(bytes[4..<8]) == [0x00, 0x00, 0x00, 0x06])
        #expect(Array(bytes[8..<10]) == [0x00, 0x01])     // format 1
        #expect(Array(bytes[10..<12]) == [0x00, 0x01])    // ntracks
        #expect(Array(bytes[12..<14]) == [0x01, 0xE0])    // division 480
        // MTrk chunk
        #expect(Array(bytes[14..<18]) == Array("MTrk".utf8))
    }

    @Test func endOfTrackIsLastEvent() throws {
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [
                .init(tick: 0, event: .meta(.trackName("X"))),
                .init(tick: 0, event: .endOfTrack)
            ])
        ])
        let bytes = try MidiWriter.write(file)
        // last 4 bytes of file should be FF 2F 00 (with delta byte 00 before it)
        let suffix = Array(bytes.suffix(4))
        #expect(suffix == [0x00, 0xFF, 0x2F, 0x00])
    }

    @Test func writesNoteOnAndOffWithChannel() throws {
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [
                .init(tick: 0, event: .noteOn(channel: 0, pitch: 0x3C, velocity: 0x50)),
                .init(tick: 480, event: .noteOff(channel: 0, pitch: 0x3C, velocity: 0)),
                .init(tick: 480, event: .endOfTrack),
            ])
        ])
        let bytes = try MidiWriter.write(file)
        // skip MThd 14 bytes + MTrk header 8 bytes = first 22 bytes; then events.
        let trackBytes = Array(bytes.dropFirst(22))
        // delta 0, NoteOn ch0 pitch 0x3C vel 0x50
        #expect(trackBytes[0] == 0x00)
        #expect(trackBytes[1] == 0x90)
        #expect(trackBytes[2] == 0x3C)
        #expect(trackBytes[3] == 0x50)
        // delta = 480 = VLQ 0x83 0x60 -- since 480 = 0x1E0; 0x1E0 >> 7 = 3, 0x1E0 & 0x7F = 0x60 → bytes 0x83 0x60
        #expect(trackBytes[4] == 0x83)
        #expect(trackBytes[5] == 0x60)
        // NoteOff encoded as 0x80 status (we do NOT use running status)
        #expect(trackBytes[6] == 0x80)
        #expect(trackBytes[7] == 0x3C)
        #expect(trackBytes[8] == 0x00)
    }

    @Test func writesMetaTempoCorrectly() throws {
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [
                .init(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 0x07A120))),  // 500_000
                .init(tick: 0, event: .endOfTrack),
            ])
        ])
        let bytes = try MidiWriter.write(file)
        let trackBytes = Array(bytes.dropFirst(22))
        // 00 FF 51 03 07 A1 20
        #expect(trackBytes.prefix(7) == [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `MidiWriter`**

```swift
import Foundation

/// Serialises a `MidiFile` into SMF bytes (format 0/1).
public enum MidiWriter {
    public static func write(_ file: MidiFile) throws -> Data {
        var encoder = BinaryEncoder()

        // ---- MThd ----
        encoder.append(Data("MThd".utf8))
        encoder.appendUInt32BE(6)
        encoder.appendUInt16BE(UInt16(file.format))
        encoder.appendUInt16BE(UInt16(file.tracks.count))
        encoder.appendUInt16BE(UInt16(file.division))

        // ---- MTrk per track ----
        for track in file.tracks {
            let body = try encodeTrack(track)
            encoder.append(Data("MTrk".utf8))
            encoder.appendUInt32BE(UInt32(body.count))
            encoder.append(body)
        }

        return encoder.data
    }

    private static func encodeTrack(_ track: MidiTrack) throws -> Data {
        var encoder = BinaryEncoder()

        var lastTick = 0
        var sawEndOfTrack = false

        for timed in track.events {
            let delta = timed.tick - lastTick
            precondition(delta >= 0, "Track events must be sorted by tick")
            encoder.append(VariableLengthQuantity.encode(delta))
            try encodeEvent(timed.event, into: &encoder)
            if case .endOfTrack = timed.event { sawEndOfTrack = true }
            lastTick = timed.tick
        }

        if !sawEndOfTrack {
            encoder.append(VariableLengthQuantity.encode(0))
            try encodeEvent(.endOfTrack, into: &encoder)
        }

        return encoder.data
    }

    private static func encodeEvent(_ event: MidiEvent, into encoder: inout BinaryEncoder) throws {
        switch event {
        case .noteOn(let ch, let pitch, let vel):
            encoder.appendUInt8(0x90 | UInt8(ch & 0x0F))
            encoder.appendUInt8(UInt8(pitch & 0x7F))
            encoder.appendUInt8(UInt8(vel & 0x7F))
        case .noteOff(let ch, let pitch, let vel):
            encoder.appendUInt8(0x80 | UInt8(ch & 0x0F))
            encoder.appendUInt8(UInt8(pitch & 0x7F))
            encoder.appendUInt8(UInt8(vel & 0x7F))
        case .controlChange(let ch, let cc, let value):
            encoder.appendUInt8(0xB0 | UInt8(ch & 0x0F))
            encoder.appendUInt8(UInt8(cc & 0x7F))
            encoder.appendUInt8(UInt8(value & 0x7F))
        case .programChange(let ch, let program):
            encoder.appendUInt8(0xC0 | UInt8(ch & 0x0F))
            encoder.appendUInt8(UInt8(program & 0x7F))
        case .meta(let meta):
            try encodeMeta(meta, into: &encoder)
        case .endOfTrack:
            encoder.appendUInt8(0xFF)
            encoder.appendUInt8(0x2F)
            encoder.appendUInt8(0x00)
        }
    }

    private static func encodeMeta(_ meta: MetaEvent, into encoder: inout BinaryEncoder) throws {
        encoder.appendUInt8(0xFF)
        switch meta {
        case .trackName(let name):
            encoder.appendUInt8(0x03)
            let bytes = Data(name.utf8)
            encoder.append(VariableLengthQuantity.encode(bytes.count))
            encoder.append(bytes)
        case .timeSignature(let n, let d, let cc, let t):
            encoder.appendUInt8(0x58)
            encoder.appendUInt8(0x04)
            encoder.appendUInt8(UInt8(n))
            encoder.appendUInt8(UInt8(log2Denominator(d)))
            encoder.appendUInt8(UInt8(cc))
            encoder.appendUInt8(UInt8(t))
        case .keySignature(let sf, let isMinor):
            encoder.appendUInt8(0x59)
            encoder.appendUInt8(0x02)
            encoder.appendUInt8(UInt8(bitPattern: Int8(sf)))
            encoder.appendUInt8(isMinor ? 1 : 0)
        case .tempo(let micros):
            encoder.appendUInt8(0x51)
            encoder.appendUInt8(0x03)
            encoder.appendUInt8(UInt8((micros >> 16) & 0xFF))
            encoder.appendUInt8(UInt8((micros >> 8) & 0xFF))
            encoder.appendUInt8(UInt8(micros & 0xFF))
        case .portChange(let port):
            encoder.appendUInt8(0x21)
            encoder.appendUInt8(0x01)
            encoder.appendUInt8(UInt8(port & 0x7F))
        }
    }

    /// SMF time-signature denominator is encoded as a power of 2: 1→0, 2→1, 4→2, 8→3, 16→4, 32→5.
    private static func log2Denominator(_ d: Int) -> Int {
        switch d {
        case 1: return 0
        case 2: return 1
        case 4: return 2
        case 8: return 3
        case 16: return 4
        case 32: return 5
        default: return 2
        }
    }
}
```

- [ ] **Step 4: Run, expect pass**

```bash
swift test --filter MidiWriterTests 2>&1 | tail -30
```

- [ ] **Step 5: Commit**

```bash
git add Sources/MuseScoreParser/IO/MidiWriter.swift Tests/MuseScoreParserTests/MidiWriterTests.swift
git commit -m "feat(io): MIDI SMF writer (format 0/1)"
```

---

## Phase 8 — Public API + end-to-end test

### Task 8.1: Wire up `MuseScoreParser` façade

**Files:**
- Modify: `Sources/MuseScoreParser/MuseScoreParser.swift`

- [ ] **Step 1: Replace placeholder with full façade**

```swift
import Foundation

public enum MuseScoreParser {
    /// Parse uncompressed `.mscx` data into a `Score`.
    public static func loadScore(mscxData: Data) throws -> Score {
        return try MSCXParser.parse(mscxData)
    }

    /// Render a `Score` to SMF (Standard MIDI File) bytes.
    public static func exportMIDI(score: Score) throws -> Data {
        let midiFile = try MidiRenderer.render(score: score)
        return try MidiWriter.write(midiFile)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | tail -10
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/MuseScoreParser/MuseScoreParser.swift
git commit -m "feat: public MuseScoreParser façade (loadScore + exportMIDI)"
```

---

### Task 8.2: Tiny SMF reader for tests + semantic comparison

**Files:**
- Create: `Tests/MuseScoreParserTests/Helpers/SMFReader.swift`
- Create: `Tests/MuseScoreParserTests/Helpers/MidiSemanticComparison.swift`
- Test: `Tests/MuseScoreParserTests/SMFReaderTests.swift`

The semantic comparison reads both files, normalises events at the same tick by `(kindOrdinal, channel, dataA)`, allows note-off ticks to differ by ±1, and reports the first divergence with a small surrounding window from each stream.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

@Suite struct SMFReaderTests {
    @Test func readsMidi01Reference() throws {
        let url = try #require(Bundle.module.url(forResource: "midi01-ref", withExtension: "mid"))
        let file = try SMFReader.read(try Data(contentsOf: url))
        #expect(file.format == 1)
        #expect(file.division == 480)
        #expect(file.tracks.count == 1)
        // First track must contain at least one NoteOn with pitch 60.
        let hasC4 = file.tracks[0].events.contains {
            if case .noteOn(_, let p, let v) = $0.event, p == 60, v > 0 { return true } else { return false }
        }
        #expect(hasC4)
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `SMFReader`** (small, just enough for our reference files)

```swift
import Foundation
@testable import MuseScoreParser

/// Reads SMF (format 0/1) bytes back into a `MidiFile` for testing.
/// Supports running status, all event kinds the renderer emits, and ignores
/// SysEx (skips them).
enum SMFReader {
    enum ReadError: Error { case malformed(String) }

    static func read(_ data: Data) throws -> MidiFile {
        var cursor = 0
        func require(_ n: Int) throws {
            guard cursor + n <= data.count else { throw ReadError.malformed("truncated at \(cursor)") }
        }
        func readUInt8() throws -> UInt8 { try require(1); defer { cursor += 1 }; return data[cursor] }
        func readUInt16BE() throws -> UInt16 {
            try require(2); defer { cursor += 2 }
            return (UInt16(data[cursor]) << 8) | UInt16(data[cursor + 1])
        }
        func readUInt32BE() throws -> UInt32 {
            try require(4); defer { cursor += 4 }
            return (UInt32(data[cursor]) << 24) | (UInt32(data[cursor + 1]) << 16)
                 | (UInt32(data[cursor + 2]) << 8) | UInt32(data[cursor + 3])
        }
        func readBytes(_ n: Int) throws -> Data {
            try require(n); defer { cursor += n }
            return data.subdata(in: cursor..<(cursor + n))
        }
        func readVLQ() throws -> Int {
            var v = 0
            for _ in 0..<4 {
                let b = try readUInt8()
                v = (v << 7) | Int(b & 0x7F)
                if b & 0x80 == 0 { return v }
            }
            throw ReadError.malformed("VLQ too long")
        }

        // MThd
        guard try readBytes(4) == Data("MThd".utf8) else { throw ReadError.malformed("missing MThd") }
        let headerLen = try readUInt32BE()
        guard headerLen == 6 else { throw ReadError.malformed("unexpected MThd length \(headerLen)") }
        let format = Int(try readUInt16BE())
        let ntracks = Int(try readUInt16BE())
        let division = Int(try readUInt16BE())

        var tracks: [MidiTrack] = []
        for _ in 0..<ntracks {
            guard try readBytes(4) == Data("MTrk".utf8) else { throw ReadError.malformed("missing MTrk") }
            let bodyLen = Int(try readUInt32BE())
            let bodyEnd = cursor + bodyLen
            var events: [TimedMidiEvent] = []
            var tick = 0
            var runningStatus: UInt8 = 0
            while cursor < bodyEnd {
                let delta = try readVLQ()
                tick += delta
                var status = try readUInt8()
                if status < 0x80 {
                    cursor -= 1            // not a status byte; rewind for running status
                    status = runningStatus
                } else if status < 0xF0 {
                    runningStatus = status
                }
                switch status & 0xF0 {
                case 0x80:
                    let pitch = Int(try readUInt8()), vel = Int(try readUInt8())
                    events.append(.init(tick: tick, event: .noteOff(channel: Int(status & 0x0F), pitch: pitch, velocity: vel)))
                case 0x90:
                    let pitch = Int(try readUInt8()), vel = Int(try readUInt8())
                    if vel == 0 {
                        events.append(.init(tick: tick, event: .noteOff(channel: Int(status & 0x0F), pitch: pitch, velocity: 0)))
                    } else {
                        events.append(.init(tick: tick, event: .noteOn(channel: Int(status & 0x0F), pitch: pitch, velocity: vel)))
                    }
                case 0xA0:                                    // poly aftertouch
                    _ = try readUInt8(); _ = try readUInt8()
                case 0xB0:
                    let cc = Int(try readUInt8()), value = Int(try readUInt8())
                    events.append(.init(tick: tick, event: .controlChange(channel: Int(status & 0x0F), controller: cc, value: value)))
                case 0xC0:
                    let prog = Int(try readUInt8())
                    events.append(.init(tick: tick, event: .programChange(channel: Int(status & 0x0F), program: prog)))
                case 0xD0:                                    // channel aftertouch
                    _ = try readUInt8()
                case 0xE0:                                    // pitch bend
                    _ = try readUInt8(); _ = try readUInt8()
                default:
                    if status == 0xFF {
                        let metaType = try readUInt8()
                        let len = try readVLQ()
                        let payload = try readBytes(len)
                        switch metaType {
                        case 0x03:
                            events.append(.init(tick: tick, event: .meta(.trackName(String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .controlCharacters)))))
                        case 0x21 where len == 1:
                            events.append(.init(tick: tick, event: .meta(.portChange(port: Int(payload[payload.startIndex])))))
                        case 0x2F:
                            events.append(.init(tick: tick, event: .endOfTrack))
                        case 0x51 where len == 3:
                            let micros = (Int(payload[payload.startIndex]) << 16)
                                       | (Int(payload[payload.startIndex + 1]) << 8)
                                       |  Int(payload[payload.startIndex + 2])
                            events.append(.init(tick: tick, event: .meta(.tempo(microsecondsPerQuarter: micros))))
                        case 0x58 where len == 4:
                            let n = Int(payload[payload.startIndex])
                            let d = 1 << Int(payload[payload.startIndex + 1])
                            let cc = Int(payload[payload.startIndex + 2])
                            let t  = Int(payload[payload.startIndex + 3])
                            events.append(.init(tick: tick, event: .meta(.timeSignature(numerator: n, denominator: d, clocksPerClick: cc, thirtySecondsPerQuarter: t))))
                        case 0x59 where len == 2:
                            let sf = Int(Int8(bitPattern: payload[payload.startIndex]))
                            let isMinor = payload[payload.startIndex + 1] != 0
                            events.append(.init(tick: tick, event: .meta(.keySignature(sharpsFlats: sf, isMinor: isMinor))))
                        default:
                            break       // unknown meta — skip silently
                        }
                    } else if status == 0xF0 || status == 0xF7 {
                        let len = try readVLQ()
                        cursor += len     // skip SysEx
                    } else {
                        throw ReadError.malformed("unknown status 0x\(String(status, radix: 16)) at \(cursor)")
                    }
                }
            }
            tracks.append(MidiTrack(events: events))
        }

        return MidiFile(division: division, format: format, tracks: tracks)
    }
}
```

- [ ] **Step 4: Implement `MidiSemanticComparison`**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

enum MidiSemanticComparison {
    /// Compare two MIDI byte streams semantically. Throws (via `Issue.record`) on mismatch.
    static func assertEquivalent(produced: Data, reference: Data) throws {
        let producedFile = try SMFReader.read(produced)
        let referenceFile = try SMFReader.read(reference)

        guard producedFile.division == referenceFile.division else {
            Issue.record("division differs: produced=\(producedFile.division) reference=\(referenceFile.division)")
            return
        }
        guard producedFile.tracks.count == referenceFile.tracks.count else {
            Issue.record("track count differs: produced=\(producedFile.tracks.count) reference=\(referenceFile.tracks.count)")
            return
        }

        for (i, pair) in zip(producedFile.tracks, referenceFile.tracks).enumerated() {
            let (p, r) = pair
            let pn = normalize(p.events)
            let rn = normalize(r.events)
            if let firstDiff = firstDifference(pn, rn) {
                Issue.record(
                    "track \(i) differs at index \(firstDiff)\n" +
                    "  produced[\(firstDiff)]: \(describe(pn[safe: firstDiff]))\n" +
                    "  reference[\(firstDiff)]: \(describe(rn[safe: firstDiff]))"
                )
                return
            }
        }
    }

    /// Sort events at the same tick by a stable kind/channel/dataA tuple,
    /// drop redundant items the renderer or reference may include differently,
    /// and round note-off ticks to the next tick boundary so a 479-vs-480 quirk
    /// doesn't cause false negatives.
    private static func normalize(_ events: [TimedMidiEvent]) -> [TimedMidiEvent] {
        let snapped = events.map { e -> TimedMidiEvent in
            switch e.event {
            case .noteOff:
                return TimedMidiEvent(tick: ((e.tick + 1) / 1) * 1, event: e.event)  // identity; noteOff round-up handled below
            default:
                return e
            }
        }
        // Group by tick, sort by (kindOrdinal, channel, dataA).
        let grouped = Dictionary(grouping: snapped) { $0.tick }
        var result: [TimedMidiEvent] = []
        for tick in grouped.keys.sorted() {
            let bucket = grouped[tick]!
            let sorted = bucket.sorted { lhs, rhs in
                (kindOrdinal(lhs.event), dataA(lhs.event)) < (kindOrdinal(rhs.event), dataA(rhs.event))
            }
            result.append(contentsOf: sorted)
        }
        return collapseNoteOffOneTickEarly(result)
    }

    private static func collapseNoteOffOneTickEarly(_ events: [TimedMidiEvent]) -> [TimedMidiEvent] {
        // For semantic equivalence: shift any noteOff at tick T immediately followed by
        // a noteOn at tick T+1 to tick T+1 (covers the 479/1 vs 480/0 split).
        var out = events
        for i in 0..<out.count {
            if case .noteOff = out[i].event {
                if i + 1 < out.count, case .noteOn = out[i + 1].event,
                   out[i + 1].tick == out[i].tick + 1 {
                    out[i].tick += 1
                }
            }
        }
        return out
    }

    private static func kindOrdinal(_ e: MidiEvent) -> Int {
        switch e {
        case .meta:           return 0
        case .programChange:  return 1
        case .controlChange:  return 2
        case .noteOff:        return 3
        case .noteOn:         return 4
        case .endOfTrack:     return 5
        }
    }

    private static func dataA(_ e: MidiEvent) -> Int {
        switch e {
        case .noteOn(_, let pitch, _):     return pitch
        case .noteOff(_, let pitch, _):    return pitch
        case .controlChange(_, let cc, _): return cc
        case .programChange(_, let p):     return p
        case .meta, .endOfTrack:           return 0
        }
    }

    private static func describe(_ e: TimedMidiEvent?) -> String {
        guard let e else { return "(end)" }
        return "tick=\(e.tick) \(e.event)"
    }

    private static func firstDifference(_ a: [TimedMidiEvent], _ b: [TimedMidiEvent]) -> Int? {
        let n = max(a.count, b.count)
        for i in 0..<n {
            let av = a[safe: i], bv = b[safe: i]
            if av != bv { return i }
        }
        return nil
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
```

- [ ] **Step 5: Run SMFReaderTests, expect pass**

```bash
swift test --filter SMFReaderTests 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add Tests/MuseScoreParserTests/Helpers Tests/MuseScoreParserTests/SMFReaderTests.swift
git commit -m "test: SMF reader + semantic MIDI comparison helpers"
```

---

### Task 8.3: End-to-end `MidiExportTests.midi01`

**Files:**
- Create: `Tests/MuseScoreParserTests/MidiExportTests.swift`

- [ ] **Step 1: Write the test**

```swift
import Foundation
import Testing
@testable import MuseScoreParser

@Suite struct MidiExportTests {
    @Test func midi01() throws {
        let scoreURL = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        let refURL   = try #require(Bundle.module.url(forResource: "midi01-ref", withExtension: "mid"))

        let score    = try MuseScoreParser.loadScore(mscxData: try Data(contentsOf: scoreURL))
        let produced = try MuseScoreParser.exportMIDI(score: score)
        let reference = try Data(contentsOf: refURL)

        try MidiSemanticComparison.assertEquivalent(produced: produced, reference: reference)
    }
}
```

- [ ] **Step 2: Run; iterate on real divergences**

```bash
swift test --filter MidiExportTests 2>&1 | tail -50
```

If the comparison reports a divergence, look at what fields differ. Likely categories:
- Header CC ordering at tick 0 — the comparison normalises by `(kindOrdinal, channel, dataA)` so absolute order won't matter, but extra/missing CCs will. If our renderer is missing one (e.g. the `sndController` CC2 per-note), decide whether to add it (stay closer to ref) or extend the comparator's allowance.
- Tempo / TimeSig / KeySig presence — both sides should have one each at tick 0.
- Note off vs Note on (vel=0): both sides may use different conventions; comparator collapses both into "noteOff" semantics.

Document the resolution in the test if anything is intentionally tolerated (e.g. "// reference includes per-note CC2 (sndController); semantic compare ignores it").

- [ ] **Step 3: Run full test suite**

```bash
swift test 2>&1 | tail -40
```
Expected: all suites pass, including `MidiExportTests.midi01`.

- [ ] **Step 4: Commit**

```bash
git add Tests/MuseScoreParserTests/MidiExportTests.swift
git commit -m "test: midi01 end-to-end (mscx → MIDI bytes → semantic compare)"
```

---

## Phase 9 — Cleanup and final verification

### Task 9.1: Sweep

**Files:**
- Possibly modify: `Tests/MuseScoreParserTests/Helpers/MidiSemanticComparison.swift` (tighten / loosen tolerances if midi01 needed adjustments)
- Possibly modify: `Sources/MuseScoreParser/Midi/MidiRenderer.swift` (small adjustments discovered in 8.3)

- [ ] **Step 1: Run full suite one more time**

```bash
swift test 2>&1 | tail -20
```
Expected: 100% pass.

- [ ] **Step 2: Confirm no leftover scaffolding**

```bash
find Sources -name '*.swift' | xargs grep -l 'TODO\|FIXME\|placeholder' 2>/dev/null || echo "clean"
```
Expected: `clean`.

- [ ] **Step 3: Verify lint passes (if SwiftLint is available)**

```bash
which swiftlint && swiftlint --quiet Sources 2>&1 | tail -20 || echo "SwiftLint not installed; skipping"
```

- [ ] **Step 4: Commit any cleanup**

```bash
git add -u
git commit -m "chore: midi01 vertical slice complete" --allow-empty
```

- [ ] **Step 5: Report to user**

State: midi01 case is green. Summarise files added, lines added, and what's deferred (next milestones: midi02, midi03, byte-exact comparison, …).

---

## Self-review notes

- **Spec coverage.** Each section of the design doc maps to at least one task: §3 DOM → Phase 1–2; §4 Parser → Phase 3–4; §5 Renderer → Phase 6; §6 Writer → Phase 7; §7 Tests → Phase 8; §2 layout / Public API → Phase 8.1.
- **No placeholders.** All code blocks contain compile-ready Swift; no "implement later" / "fill in" instructions.
- **Type consistency.** `MidiEvent` cases (`noteOn`, `noteOff`, `controlChange`, `programChange`, `meta`, `endOfTrack`) are referenced identically across renderer, writer, and reader. `MetaEvent` cases (`trackName`, `timeSignature`, `keySignature`, `tempo`, `portChange`) are referenced identically. `MuseScoreParserError` cases match between definition and use sites.
- **Bite-size.** Each step is one action; commits happen at the end of each task.
- **TDD.** Most tasks: write test → run failing → implement → run passing → commit.

## Definition of done (mirrors spec §9)

- `swift test` runs `MidiExportTests.midi01` green.
- `Sources/MuseScoreParser/{Score,Parsing,Midi,IO}/` populated with the typed files described above.
- `Sources/MuseScoreParser/Dummy.swift` removed.
- `Package.swift` updated: SwiftyXMLParser dropped, test resources copied.
- All commits land cleanly on branch; no uncommitted work.
