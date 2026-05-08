# Note Articulations (staccato / staccatissimo / tenuto) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `<Articulation>` decode/encode for staccato / staccatissimo / tenuto on `Chord`, with `.unknown(rawSubtype)` round-trip preservation, and shorten MIDI note durations using a per-articulation gateTime lookup.

**Architecture:** New `ChordArticulation` value type stored on `Chord.articulations`. Decoder harvests `<Articulation>` children of `<Chord>` and maps SymId strings to `Kind` + `Anchor`. Encoder emits the same SymId form between `<durationType>` and lyrics, accepted by both MS3 (3.6.2+) and MS4. MIDI renderer replaces the per-instrument default gateTime with an aggregate-min lookup over the chord's in-scope articulations, falling back to existing instrument-default behaviour when no articulation is present.

**Tech Stack:** Swift Package Manager, Swift Testing (`@Test`/`#expect`), Foundation `XMLParser` via the project's `XMLTreeNode` wrapper.

**Spec:** [docs/superpowers/specs/2026-05-08-note-articulations-design.md](../specs/2026-05-08-note-articulations-design.md)

---

## File Structure

**New files:**
- `Sources/SheetMusicCore/Score/ChordArticulation.swift` — model
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift` — encoder + `subtypeXML()` helper
- `Tests/SheetMusicTests/ChordArticulationTests.swift` — decode/encode/round-trip
- `Tests/SheetMusicTests/MidiRendererArticulationTests.swift` — MIDI gateTime semantics

**Modified files:**
- `Sources/SheetMusicCore/Score/Chord.swift` — add `articulations` field (trailing, default `[]`)
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift` — harvest `<Articulation>` children and `fromSubtypeXML(_:)` private helper
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift` — emit articulations between `<durationType>` and `<Lyrics>`
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift` — replace `defaultArticulationGateTime(for:)` call with `effectiveGateTime(for:instrument:)`
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` — add `effectiveGateTime(for:instrument:)` static helper next to existing `defaultArticulationGateTime`

**Note on call site for gateTime:** the spec says "MidiRenderer+Voice.swift line 228" but the actual per-chord gateTime usage is in `MidiRenderer+Grace.swift:166` inside `renderChordWithGraces`. All chord rendering (with or without grace notes) flows through that function, so swapping that one call gives the desired effect for every chord. The `effectiveGateTime` helper itself lives in `+Voice.swift` next to `defaultArticulationGateTime`.

---

## Task 1: Add `ChordArticulation` value type

**Files:**
- Create: `Sources/SheetMusicCore/Score/ChordArticulation.swift`

- [ ] **Step 1: Write the failing test (constructor smoke + Equatable)**

Create `Tests/SheetMusicTests/ChordArticulationTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
import Testing

@Suite struct ChordArticulationTests {
    @Test func constructsKnownKindWithAnchor() {
        let art = ChordArticulation(kind: .staccato, anchor: .above)
        #expect(art.kind == .staccato)
        #expect(art.anchor == .above)
    }

    @Test func unknownPreservesRawSubtype() {
        let art = ChordArticulation(kind: .unknown(subtype: "articAccentAbove"))
        #expect(art.kind == .unknown(subtype: "articAccentAbove"))
        #expect(art.anchor == nil)
    }

    @Test func equalityIsValueBased() {
        #expect(
            ChordArticulation(kind: .tenuto, anchor: .below)
            == ChordArticulation(kind: .tenuto, anchor: .below)
        )
        #expect(
            ChordArticulation(kind: .staccato)
            != ChordArticulation(kind: .staccatissimo)
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChordArticulationTests`
Expected: FAIL — `cannot find 'ChordArticulation' in scope`

- [ ] **Step 3: Create the type**

Create `Sources/SheetMusicCore/Score/ChordArticulation.swift`:

```swift
import Foundation

/// Per-chord articulation marking. C++: `mu::engraving::Articulation`.
///
/// Currently only the duration-shaping family (staccato / staccatissimo /
/// tenuto) is consumed by the MIDI renderer. Any other subtype decoded
/// from mscx is preserved as `.unknown(subtype:)` so the encoder can
/// emit the same XML back, but the renderer ignores it.
public struct ChordArticulation: Sendable, Equatable {
    public var kind: Kind
    /// Anchor side written by MuseScore (`articStaccatoAbove` vs
    /// `…Below`). Preserved verbatim for round-trip; encoder defaults
    /// to `.above` when `nil` (matches MuseScore's default for newly
    /// created articulations).
    public var anchor: Anchor?

    public init(kind: Kind, anchor: Anchor? = nil) {
        self.kind = kind
        self.anchor = anchor
    }

    public enum Kind: Sendable, Equatable {
        case staccato
        case staccatissimo
        case tenuto
        /// Any subtype outside the in-scope set above. The raw MS4
        /// SymId (e.g. `articAccentAbove`) is preserved verbatim.
        case unknown(subtype: String)
    }

    public enum Anchor: Sendable, Equatable {
        case above
        case below
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ChordArticulationTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/ChordArticulation.swift Tests/SheetMusicTests/ChordArticulationTests.swift
git commit -m "feat(core): add ChordArticulation value type"
```

---

## Task 2: Add `articulations` field to `Chord`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Chord.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/ChordArticulationTests.swift`:

```swift
    @Test func chordStoresArticulations() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60)]),
            articulations: [ChordArticulation(kind: .staccato, anchor: .above)]
        )
        #expect(chord.articulations.count == 1)
        #expect(chord.articulations[0].kind == .staccato)
    }

    @Test func chordDefaultsToEmptyArticulations() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60)])
        )
        #expect(chord.articulations.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChordArticulationTests`
Expected: FAIL — `extra argument 'articulations' in call`

- [ ] **Step 3: Add field + initializer parameter to `Chord`**

Modify `Sources/SheetMusicCore/Score/Chord.swift` — add a stored property after `graceNotesAfter` and a trailing initializer parameter (per spec: "trailing default"):

```swift
public struct Chord: Sendable, Equatable {
    public var duration: NoteDuration
    public var notes: ChordNotes
    public var arpeggio: Arpeggio?
    public var lyrics: [Lyric]
    public var graceNotesBefore: [GraceChord]
    public var graceNotesAfter: [GraceChord]
    /// Chord-level articulations (staccato / staccatissimo / tenuto and
    /// round-trip-preserved unknowns). C++: `Chord::_articulations`.
    public var articulations: [ChordArticulation]

    public init(
        duration: NoteDuration,
        notes: ChordNotes,
        arpeggio: Arpeggio? = nil,
        lyrics: [Lyric] = [],
        graceNotesBefore: [GraceChord] = [],
        graceNotesAfter: [GraceChord] = [],
        articulations: [ChordArticulation] = []
    ) {
        self.duration = duration
        self.notes = notes
        self.arpeggio = arpeggio
        self.lyrics = lyrics
        self.graceNotesBefore = graceNotesBefore
        self.graceNotesAfter = graceNotesAfter
        self.articulations = articulations
    }
}
```

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter ChordArticulationTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Run full test suite to confirm source compatibility**

Run: `swift test`
Expected: PASS — all 200+ existing `Chord(duration:...)` call sites remain compatible because every new param has a default.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/Score/Chord.swift Tests/SheetMusicTests/ChordArticulationTests.swift
git commit -m "feat(core): add Chord.articulations field"
```

---

## Task 3: Decode `<Articulation>` children from `<Chord>`

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`

- [ ] **Step 1: Write the failing decode tests**

Append to `Tests/SheetMusicTests/ChordArticulationTests.swift` (also extend imports at top of file: add `@testable import SheetMusicMSCX` and `@testable import SheetMusicXMLTools` next to the existing `@testable import SheetMusicCore`):

```swift
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
```

Then append these tests:

```swift
    private func parseChord(_ inner: String) throws -> Chord {
        let xml = "<Chord>\(inner)</Chord>"
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        return try Chord.decode(root)
    }

    @Test func decodesSingleStaccatoAbove() throws {
        let chord = try parseChord("""
            <durationType>quarter</durationType>
            <Articulation><subtype>articStaccatoAbove</subtype></Articulation>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
            """)
        #expect(chord.articulations == [ChordArticulation(kind: .staccato, anchor: .above)])
    }

    @Test func decodesMultipleArticulationsPreservingOrderAndAnchors() throws {
        let chord = try parseChord("""
            <durationType>quarter</durationType>
            <Articulation><subtype>articStaccatoAbove</subtype></Articulation>
            <Articulation><subtype>articTenutoBelow</subtype></Articulation>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
            """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .staccato, anchor: .above),
            ChordArticulation(kind: .tenuto, anchor: .below),
        ])
    }

    @Test func decodesUnknownSubtypeAsUnknownVariant() throws {
        let chord = try parseChord("""
            <durationType>quarter</durationType>
            <Articulation><subtype>articAccentAbove</subtype></Articulation>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
            """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .unknown(subtype: "articAccentAbove"))
        ])
    }

    @Test func decodesEmptySubtypeAsUnknownEmpty() throws {
        // MuseScore never emits this; permissive-parser convention says don't throw.
        let chord = try parseChord("""
            <durationType>quarter</durationType>
            <Articulation><subtype></subtype></Articulation>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
            """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .unknown(subtype: ""))
        ])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ChordArticulationTests`
Expected: FAIL — `chord.articulations` is empty (decoder doesn't read `<Articulation>` yet).

- [ ] **Step 3: Implement decoder harvest + helper**

Modify `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`. After the `arpeggio` block (before the lyrics block), add:

```swift
        let articulations = node.all("Articulation").map { artNode -> ChordArticulation in
            let subtype = artNode.first("subtype")?.text ?? ""
            return ChordArticulation.fromSubtypeXML(subtype)
        }
```

And update the trailing `return Chord(...)` to pass `articulations: articulations`. The full call becomes:

```swift
        return Chord(
            duration: duration, notes: ChordNotes(notes),
            arpeggio: arpeggio, lyrics: lyrics,
            articulations: articulations
        )
```

Then add the private helper at the bottom of the same file (still inside `extension Chord`):

```swift
    /// Map an MS4 SymId-style `<subtype>` string to a ChordArticulation.
    /// Unknown / empty values fall through to `.unknown(...)` with
    /// `anchor == nil` so the original string round-trips verbatim.
    static func fromSubtypeXML(_ subtype: String) -> ChordArticulation {
        let anchor: ChordArticulation.Anchor?
        let base: String
        if subtype.hasSuffix("Above") {
            anchor = .above
            base = String(subtype.dropLast("Above".count))
        } else if subtype.hasSuffix("Below") {
            anchor = .below
            base = String(subtype.dropLast("Below".count))
        } else {
            anchor = nil
            base = subtype
        }
        switch base {
        case "articStaccato":      return .init(kind: .staccato, anchor: anchor)
        case "articStaccatissimo": return .init(kind: .staccatissimo, anchor: anchor)
        case "articTenuto":        return .init(kind: .tenuto, anchor: anchor)
        default:                   return .init(kind: .unknown(subtype: subtype))
        }
    }
}
```

Wait — `fromSubtypeXML` lives on `ChordArticulation`, not `Chord`. Move it: rather than nesting inside `extension Chord`, put it in a new `extension ChordArticulation` block at the bottom of `MSCXDecoder+Chord.swift`:

```swift
extension ChordArticulation {
    /// Map an MS4 SymId-style `<subtype>` string to a ChordArticulation.
    /// Unknown / empty values fall through to `.unknown(...)` with
    /// `anchor == nil` so the original string round-trips verbatim.
    static func fromSubtypeXML(_ subtype: String) -> ChordArticulation {
        let anchor: ChordArticulation.Anchor?
        let base: String
        if subtype.hasSuffix("Above") {
            anchor = .above
            base = String(subtype.dropLast("Above".count))
        } else if subtype.hasSuffix("Below") {
            anchor = .below
            base = String(subtype.dropLast("Below".count))
        } else {
            anchor = nil
            base = subtype
        }
        switch base {
        case "articStaccato":      return .init(kind: .staccato, anchor: anchor)
        case "articStaccatissimo": return .init(kind: .staccatissimo, anchor: anchor)
        case "articTenuto":        return .init(kind: .tenuto, anchor: anchor)
        default:                   return .init(kind: .unknown(subtype: subtype))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ChordArticulationTests`
Expected: PASS (9 tests)

- [ ] **Step 5: Run the full suite as a regression guard**

Run: `swift test`
Expected: All tests still pass (200+ existing tests, decoder change is additive).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift Tests/SheetMusicTests/ChordArticulationTests.swift
git commit -m "feat(mscx): decode chord-level <Articulation> elements"
```

---

## Task 4: Encode chord articulations back to MSCX

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`

- [ ] **Step 1: Write the failing encode + round-trip tests**

Append to `Tests/SheetMusicTests/ChordArticulationTests.swift`:

```swift
    private func encodedSubtypes(_ articulations: [ChordArticulation]) -> [String] {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60)]),
            articulations: articulations
        )
        let xml = chord.encodeAsChord()
        return xml.all("Articulation").compactMap { $0.first("subtype")?.text }
    }

    @Test func encodesDefaultAnchorAsAbove() {
        // anchor == nil should serialize as the "Above" SymId variant.
        #expect(encodedSubtypes([.init(kind: .staccato)]) == ["articStaccatoAbove"])
    }

    @Test func encodesExplicitBelowAnchor() {
        #expect(encodedSubtypes([.init(kind: .staccatissimo, anchor: .below)])
                == ["articStaccatissimoBelow"])
    }

    @Test func encodesUnknownVerbatim() {
        // Unknown round-trips its raw string and ignores anchor.
        #expect(encodedSubtypes([.init(kind: .unknown(subtype: "articAccentAbove"))])
                == ["articAccentAbove"])
    }

    @Test func articulationsEncodeBetweenDurationAndNotes() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60)]),
            articulations: [.init(kind: .staccato, anchor: .above)]
        )
        let xml = chord.encodeAsChord()
        let names = xml.children.map(\.name)
        let durIdx = try? #require(names.firstIndex(of: "durationType"))
        let artIdx = try? #require(names.firstIndex(of: "Articulation"))
        let noteIdx = try? #require(names.firstIndex(of: "Note"))
        #expect(durIdx! < artIdx!)
        #expect(artIdx! < noteIdx!)
    }

    @Test func encodeDecodeRoundTripsAllKinds() throws {
        let original = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60)]),
            articulations: [
                .init(kind: .staccato, anchor: .above),
                .init(kind: .staccatissimo, anchor: .below),
                .init(kind: .tenuto, anchor: .above),
                .init(kind: .unknown(subtype: "articAccentAbove")),
            ]
        )
        let xml = original.encodeAsChord()
        let serialized = XMLTreeWriter.write(xml)
        let parsed = try XMLTreeParser.parse(Data(serialized.utf8))
        let roundTripped = try Chord.decode(parsed)
        #expect(roundTripped.articulations == original.articulations)
    }
```

If `XMLTreeWriter.write(...)` is named differently in the codebase, substitute the matching pretty/compact serializer. (Check `Sources/SheetMusicMSCX` or `Sources/SheetMusicXMLTools` for the actual entry point if `XMLTreeWriter.write` doesn't compile.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ChordArticulationTests`
Expected: FAIL — `chord.encodeAsChord()` does not yet emit `<Articulation>` children.

- [ ] **Step 3: Add the encoder helper**

Create `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension ChordArticulation {
    /// Build an `<Articulation><subtype>…</subtype></Articulation>`
    /// element. Inverse of `MSCXDecoder+Chord`'s harvest path.
    /// Both MS3 (3.6.2+) and MS4 readers accept the SymId-string form.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        XMLTreeNode(
            name: "Articulation",
            children: [XMLTreeNode(name: "subtype", text: subtypeXML())]
        )
    }

    /// Build the `<subtype>` payload. `unknown` writes the raw string
    /// verbatim (anchor ignored). Known kinds default `nil` anchor to
    /// `Above`, matching MuseScore's default for newly created
    /// articulations.
    func subtypeXML() -> String {
        if case let .unknown(raw) = kind {
            return raw
        }
        let suffix: String
        switch anchor {
        case .below:        suffix = "Below"
        case .above, .none: suffix = "Above"
        }
        switch kind {
        case .staccato:        return "articStaccato\(suffix)"
        case .staccatissimo:   return "articStaccatissimo\(suffix)"
        case .tenuto:          return "articTenuto\(suffix)"
        case .unknown:         return ""  // unreachable — handled above
        }
    }
}
```

- [ ] **Step 4: Wire articulations into `<Chord>` encoding**

Modify `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`. Insert the articulation loop between the `duration.appendDurationXML` line and the lyrics loop. The relevant region becomes:

```swift
        duration.appendDurationXML(to: &children)
        // Articulations sit between durationType and the first <Lyrics>/<Note>:
        // matches MuseScore's Chord::write ordering and is accepted by both
        // MS3 (3.6.2+) and MS4 readers. C++:
        //   engraving/dom/chord.cpp Chord::write — durationType → StemDirection
        //   → ChordLine / Articulation / Tremolo → Lyrics → Note.
        for art in articulations {
            children.append(art.encode(options: options))
        }
        for lyric in lyrics where !lyric.text.isEmpty {
            children.append(lyric.encode(options: options))
        }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ChordArticulationTests`
Expected: PASS (14 tests)

- [ ] **Step 6: Run full suite (encoder change is on a hot path — guard against regressions)**

Run: `swift test`
Expected: All previous tests still pass; encoded MSCX now has `<Articulation>` only when `chord.articulations` is non-empty (default `[]` callers emit no element).

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift Tests/SheetMusicTests/ChordArticulationTests.swift
git commit -m "feat(mscx): encode chord-level <Articulation> elements"
```

---

## Task 5: MIDI gateTime — `effectiveGateTime` helper

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`
- Create: `Tests/SheetMusicTests/MidiRendererArticulationTests.swift`

This task writes the helper and unit-tests it directly — it does not yet swap the call site. That swap lands in Task 6 once the helper is verified in isolation.

- [ ] **Step 1: Write the failing helper unit tests**

Create `Tests/SheetMusicTests/MidiRendererArticulationTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiRendererArticulationTests {
    private let bareInstrument = Instrument(
        articulations: [InstrumentArticulation(name: nil, velocity: 100, gateTime: 95)]
    )

    private func chord(_ arts: [ChordArticulation.Kind]) -> Chord {
        Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60)]),
            articulations: arts.map { ChordArticulation(kind: $0) }
        )
    }

    @Test func noArticulationFallsBackToInstrumentDefault() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([]), instrument: bareInstrument
        )
        #expect(gate == 95)  // unnamed-default preset value
    }

    @Test func staccatoUsesHardcodedFallbackWhenPresetMissing() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccato]), instrument: bareInstrument
        )
        #expect(gate == 50)
    }

    @Test func staccatoUsesInstrumentPresetWhenPresent() {
        let inst = Instrument(articulations: [
            InstrumentArticulation(name: nil, velocity: 100, gateTime: 95),
            InstrumentArticulation(name: "staccato", velocity: 100, gateTime: 25),
        ])
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccato]), instrument: inst
        )
        #expect(gate == 25)
    }

    @Test func staccatissimoDefaultsToThirtyThree() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccatissimo]), instrument: bareInstrument
        )
        #expect(gate == 33)
    }

    @Test func tenutoDefaultsToOneHundred() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.tenuto]), instrument: bareInstrument
        )
        #expect(gate == 100)
    }

    @Test func multipleInScopeArticulationsTakeMinimumGate() {
        // staccato (50) + tenuto (100) → 50 wins. Mirrors
        // MuseScore's MidiArticulation::aggregateOf behaviour.
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccato, .tenuto]), instrument: bareInstrument
        )
        #expect(gate == 50)
    }

    @Test func unknownArticulationFallsThroughToInstrumentDefault() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60)]),
            articulations: [.init(kind: .unknown(subtype: "articAccentAbove"))]
        )
        let gate = MidiRenderer.effectiveGateTime(
            for: chord, instrument: bareInstrument
        )
        #expect(gate == 95)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MidiRendererArticulationTests`
Expected: FAIL — `'effectiveGateTime' is not a member of MidiRenderer` (or access-level error).

- [ ] **Step 3: Implement `effectiveGateTime` in `MidiRenderer+Voice.swift`**

Modify `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`. Add after `defaultArticulationGateTime(for:)`:

```swift
    /// Per-chord gateTime lookup. Filters `chord.articulations` to the
    /// in-scope duration-shaping kinds (staccato / staccatissimo /
    /// tenuto), looks each up in the instrument preset table, and
    /// returns the **minimum** gateTime% among the candidates (matches
    /// MuseScore's `MidiArticulation::aggregateOf` — most-shortening
    /// wins). When no in-scope articulation is present, falls through
    /// to `defaultArticulationGateTime(for:)` so existing behaviour is
    /// preserved. C++:
    ///   engraving/compat/midi/compatmidirender.cpp
    ///   `CompatMidiRender::collectMeasureEvents` — `articulationGateTime`.
    static func effectiveGateTime(for chord: Chord, instrument: Instrument) -> Int {
        let gates = chord.articulations.compactMap { art -> Int? in
            let presetName: String
            let hardcodedDefault: Int
            switch art.kind {
            case .staccato:        presetName = "staccato";      hardcodedDefault = 50
            case .staccatissimo:   presetName = "staccatissimo"; hardcodedDefault = 33
            case .tenuto:          presetName = "tenuto";        hardcodedDefault = 100
            case .unknown:         return nil
            }
            return instrument.articulations
                .first(where: { $0.name == presetName })?
                .gateTime ?? hardcodedDefault
        }
        if let minimum = gates.min() {
            return minimum
        }
        return defaultArticulationGateTime(for: instrument)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MidiRendererArticulationTests`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift Tests/SheetMusicTests/MidiRendererArticulationTests.swift
git commit -m "feat(midi): add per-chord effectiveGateTime helper"
```

---

## Task 6: Wire `effectiveGateTime` into chord rendering

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift`

- [ ] **Step 1: Write the failing end-to-end MIDI tests**

Append to `Tests/SheetMusicTests/MidiRendererArticulationTests.swift`. These build a single-measure Score programmatically and assert on rendered note-on/note-off ticks, covering spec test cases 6–12 end-to-end. (Adjust the `Score(...)` / `Part(...)` / `Staff(...)` / `Measure(...)` / `Voice(...)` initializer arguments to match the actual signatures in `Sources/SheetMusicCore/Score/`. If unsure of the exact init shape, mirror an existing programmatic-build test such as `MidiRendererTieTests.swift` or `MidiRendererGlissandoTests.swift`.)

```swift
    private func renderSingleChord(
        _ chord: Chord,
        division: Int = 480,
        instrument: Instrument = Instrument()
    ) -> [TimedMidiEvent] {
        let voice = Voice(elements: [.chord(chord)])
        let measure = Measure(voices: [voice])
        let part = Part(
            instrument: instrument,
            staves: [Staff(measures: [measure])]
        )
        let score = Score(parts: [part])
        let file = try! MidiRenderer.render(score: score)
        return file.tracks[0].events
    }

    private func gateTicks(
        from events: [TimedMidiEvent],
        durationTicks: Int = 480
    ) -> Int {
        // Find the first noteOn (vel > 0) and the matching noteOff.
        guard let on = events.first(where: {
            if case let .noteOn(_, _, v) = $0.event, v > 0 { return true }
            return false
        }) else { return -1 }
        guard let off = events.first(where: {
            if case .noteOff = $0.event { return true }
            if case let .noteOn(_, _, v) = $0.event, v == 0 { return true }
            return false
        }) else { return -1 }
        // Renderer emits off at on + gatedTicks - 1; recover the gated length.
        return off.tick - on.tick + 1
    }

    @Test func endToEndStaccatoShortensToFiftyPercent() {
        let events = renderSingleChord(chord([.staccato]))
        // 480 ticks * 50% = 240 ticks gated.
        #expect(gateTicks(from: events) == 240)
    }

    @Test func endToEndTenutoKeepsFullDuration() {
        let events = renderSingleChord(chord([.tenuto]))
        #expect(gateTicks(from: events) == 480)
    }

    @Test func endToEndStaccatissimoShortensToThirtyThreePercent() {
        let events = renderSingleChord(chord([.staccatissimo]))
        // 480 * 33% = 158 (integer truncation).
        #expect(gateTicks(from: events) == 158)
    }

    @Test func endToEndNoArticulationUsesInstrumentDefault() {
        // Default Instrument with no articulations table → gateTime fallback 100%.
        let events = renderSingleChord(chord([]))
        #expect(gateTicks(from: events) == 480)
    }
```

- [ ] **Step 2: Run tests to verify the staccato/staccatissimo cases fail**

Run: `swift test --filter MidiRendererArticulationTests`
Expected: FAIL on `endToEndStaccatoShortensToFiftyPercent` and `endToEndStaccatissimoShortensToThirtyThreePercent` (current code emits 480-tick noteOffs because the call site still uses the unnamed default). The tenuto / no-articulation cases should already pass.

- [ ] **Step 3: Swap the call site in `MidiRenderer+Grace.swift`**

Modify `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift`. Find line 166:

```swift
        let gate = defaultArticulationGateTime(for: instrument)
```

Replace with:

```swift
        let gate = effectiveGateTime(for: chord, instrument: instrument)
```

(The `chord` local is already in scope inside `renderChordWithGraces` — no other plumbing needed.)

- [ ] **Step 4: Run the focused tests**

Run: `swift test --filter MidiRendererArticulationTests`
Expected: PASS (11 tests total in this suite)

- [ ] **Step 5: Run the full suite — no regressions**

Run: `swift test`
Expected: All tests pass. The chord-rendering hot path now consults `effectiveGateTime`, but with empty `chord.articulations` the helper returns `defaultArticulationGateTime(for:)` so existing behaviour is bit-identical for every existing test case (including `MidiExportTests`).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift Tests/SheetMusicTests/MidiRendererArticulationTests.swift
git commit -m "feat(midi): apply chord articulations to note durations"
```

---

## Task 7: Final verification + cleanup

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: 0 failures across all suites (the project currently has 48+ tests, this PR adds ~25 new ones).

- [ ] **Step 2: Run SwiftLint**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors. If a new file trips the 300-line cap, split it (the encoder file is small; only `MidiRendererArticulationTests.swift` is at risk — split into a `+EndToEnd` suite if needed).

- [ ] **Step 3: Build the example app to ensure source-compat across the public Chord API**

```bash
cd Example && xcodegen generate
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED. The added `Chord` parameter has a default, so existing example call sites continue to compile.

- [ ] **Step 4: Manual MS3 sanity check (per spec "Risks")**

Take any test mscx that has a chord (e.g. `Tests/SheetMusicTests/Resources/midi01.mscx`), construct a Score with one staccato added programmatically, encode to mscx, and open the result in native MuseScore 3.6.2 (the user runs this — ask the user to verify visually). The dot should appear above the affected note; no parse error dialog. This is a one-time sanity check, not a CI gate.

If MS3 rejects the file, fall back to `MSCXEncoderOptions.targetVersion == .v3` branching (write the integer-id form for v3) and add a regression test. The spec rates this risk as low because `midi01.mscx` already uses the SymId form natively.

- [ ] **Step 5: No extra commit needed if tests/lint pass**

If lint or the example app surfaced a fix, commit it as a follow-up:

```bash
git add -p
git commit -m "chore: address lint / example-app fallout from articulations"
```

---

## Self-Review Notes

Spec coverage cross-check:

| Spec section | Task |
|---|---|
| Core model — `ChordArticulation` | Task 1 |
| Core model — `Chord.articulations` field | Task 2 |
| Decoder — `<Articulation>` harvest + `fromSubtypeXML` | Task 3 |
| Encoder — placement between durationType and lyrics | Task 4 |
| Encoder — `MSCXEncoder+ChordArticulation.swift` | Task 4 |
| MIDI rendering — `effectiveGateTime` aggregate-min | Task 5 |
| MIDI rendering — call-site swap | Task 6 |
| Tests 1–5 (decode/encode/round-trip) | Task 3 + Task 4 |
| Tests 6–12 (MIDI gateTime) | Task 5 (helper) + Task 6 (end-to-end) |
| MS3 sanity check (risk #1) | Task 7 |
| Editor APIs — explicitly out of scope | n/a |
| `MidiExportTests` fixture — explicitly out of scope (no `*-ref.mid`) | n/a |

Type/name consistency: `ChordArticulation`, `ChordArticulation.Kind`, `ChordArticulation.Anchor`, `fromSubtypeXML(_:)` (decoder helper), `subtypeXML()` (encoder helper), `effectiveGateTime(for:instrument:)` (renderer helper). All used identically across tasks.
