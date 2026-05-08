# Velocity-Shaping Articulations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship accent / marcato + the two combined SymIds (accent-staccato, marcato-staccato) end-to-end: MSCX round-trip, MIDI velocity (and combined-kind gateTime) shortening, and SMuFL glyph rendering.

**Architecture:** Mirror the staccato/tenuto PR. Extend `ChordArticulation.Kind` with four cases; thread them through the existing decoder switch, encoder switch, `effectiveGateTime`, the `LayoutElement.articulation` emitter, and the `ArticulationRenderer.glyph` switch. Add a sibling `effectiveVelocityScale` (MAX aggregate) and a per-chord `adjustVelocityForChord` modifier called inside `renderChordWithGraces` so only the main-chord noteOns get boosted (graces stay on the unmodified running velocity).

**Tech Stack:** Swift Package (swift-sheet-music), Swift Testing (`@Test` / `#expect`), Bravura SMuFL font, CALayer-based UI.

**Spec:** `docs/superpowers/specs/2026-05-09-velocity-articulations-design.md`

**Build / test commands** (run from repo root):

```bash
swift build
swift test --filter ChordArticulationVelocityTests
swift test --filter MidiRendererVelocityArticulationTests
swift test --filter LayoutVelocityArticulationTests
swift test --filter ScoreLayerBuilderTests
swift test                            # full suite — should be 100% green at end
swiftlint --quiet Sources Tests       # 0 warnings
```

---

### Task 1: Decoder + Encoder + Model — four new Kind cases

**Files:**
- Modify: `Sources/SheetMusicCore/Score/ChordArticulation.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift` (lines 90–96, the inner `switch base`)
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift` (lines 30–35, the `switch kind`)
- Test (new): `Tests/SheetMusicTests/ChordArticulationVelocityTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SheetMusicTests/ChordArticulationVelocityTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite struct ChordArticulationVelocityTests {
    private func parseChord(_ inner: String) throws -> Chord {
        let xml = "<Chord>\(inner)</Chord>"
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        return try Chord.decode(root)
    }

    @Test func decodesAccentAbove() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articAccentAbove</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .accent, anchor: .above),
        ])
    }

    @Test func decodesMarcatoBelow() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articMarcatoBelow</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .marcato, anchor: .below),
        ])
    }

    @Test func decodesAccentStaccatoCombinedNotPlainAccent() throws {
        // Guard against a future regression where the prefix "articAccent"
        // matched first and ate the combined SymId.
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articAccentStaccatoAbove</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .accentStaccato, anchor: .above),
        ])
    }

    @Test func decodesMarcatoStaccatoBelow() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articMarcatoStaccatoBelow</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .marcatoStaccato, anchor: .below),
        ])
    }

    private func encodedSubtypes(_ articulations: [ChordArticulation]) -> [String] {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: articulations
        )
        let xml = chord.encodeAsChord()
        return xml.all("Articulation").compactMap { $0.first("subtype")?.text }
    }

    @Test func encodesAllNewKinds() {
        #expect(
            encodedSubtypes([
                .init(kind: .accent, anchor: .above),
                .init(kind: .marcato, anchor: .below),
                .init(kind: .accentStaccato, anchor: .above),
                .init(kind: .marcatoStaccato, anchor: .below),
            ]) == [
                "articAccentAbove",
                "articMarcatoBelow",
                "articAccentStaccatoAbove",
                "articMarcatoStaccatoBelow",
            ]
        )
    }

    @Test func encodesNilAnchorAsAbove() {
        #expect(
            encodedSubtypes([.init(kind: .accent)]) == ["articAccentAbove"]
        )
    }

    @Test func roundTripsAllNewKinds() throws {
        let original = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [
                .init(kind: .accent, anchor: .above),
                .init(kind: .marcato, anchor: .below),
                .init(kind: .accentStaccato, anchor: .above),
                .init(kind: .marcatoStaccato, anchor: .below),
            ]
        )
        let xml = original.encodeAsChord()
        let serialized = XMLTreeSerializer.serialize(xml)
        let parsed = try XMLTreeParser.parse(serialized)
        let roundTripped = try Chord.decode(parsed)
        #expect(roundTripped.articulations == original.articulations)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ChordArticulationVelocityTests`
Expected: compile error — "type `ChordArticulation.Kind` has no case `accent`" (and the other three).

- [ ] **Step 3: Add the four new Kind cases**

In `Sources/SheetMusicCore/Score/ChordArticulation.swift`, replace the `Kind` enum body so it reads:

```swift
public enum Kind: Sendable, Equatable {
    case staccato
    case staccatissimo
    case tenuto
    case accent             // articAccentAbove/Below
    case marcato            // articMarcatoAbove/Below
    case accentStaccato     // articAccentStaccatoAbove/Below
    case marcatoStaccato    // articMarcatoStaccatoAbove/Below
    /// Any subtype outside the in-scope set above. The raw MS4
    /// SymId (e.g. `articSoftAccentAbove`) is preserved verbatim.
    case unknown(subtype: String)
}
```

Update the file-leading doc comment to say "duration-shaping family +
velocity-shaping family" instead of just duration-shaping.

- [ ] **Step 4: Extend the decoder switch**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`, replace the inner `switch base` (currently lines 90–96) with:

```swift
switch base {
case "articStaccato":          return .init(kind: .staccato, anchor: anchor)
case "articStaccatissimo":     return .init(kind: .staccatissimo, anchor: anchor)
case "articTenuto":            return .init(kind: .tenuto, anchor: anchor)
case "articAccent":            return .init(kind: .accent, anchor: anchor)
case "articMarcato":           return .init(kind: .marcato, anchor: anchor)
case "articAccentStaccato":    return .init(kind: .accentStaccato, anchor: anchor)
case "articMarcatoStaccato":   return .init(kind: .marcatoStaccato, anchor: anchor)
default:                       return .init(kind: .unknown(subtype: subtype))
}
```

The switch is exact-match on the suffix-stripped stem, so order is irrelevant — the combined SymIds match their full stripped name (e.g. `articAccentStaccato`), not the `articAccent` prefix.

- [ ] **Step 5: Extend the encoder switch**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift`, replace the inner `switch kind` (currently lines 30–35) with:

```swift
switch kind {
case .staccato:         return "articStaccato\(suffix)"
case .staccatissimo:    return "articStaccatissimo\(suffix)"
case .tenuto:           return "articTenuto\(suffix)"
case .accent:           return "articAccent\(suffix)"
case .marcato:          return "articMarcato\(suffix)"
case .accentStaccato:   return "articAccentStaccato\(suffix)"
case .marcatoStaccato:  return "articMarcatoStaccato\(suffix)"
case .unknown:          return "" // unreachable — handled above
}
```

- [ ] **Step 6: Run tests to verify they pass and existing tests still pass**

Run: `swift test --filter ChordArticulationVelocityTests`
Expected: all 7 tests PASS.

Run: `swift test --filter ChordArticulationTests`
Expected: existing 12 tests still PASS (regression guard for staccato/tenuto round-trip and the `decodesUnknownSubtypeAsUnknownVariant` case — note that test will continue to expect `articSoftAccentAbove` (or whichever string) to remain `.unknown`; the existing test uses `articAccentAbove` which now decodes to `.accent` rather than `.unknown`, so it will fail).

If `decodesUnknownSubtypeAsUnknownVariant` fails (because `articAccentAbove` is no longer "unknown"), update that test to use a still-out-of-scope SymId such as `articSoftAccentAbove`:

```swift
@Test func decodesUnknownSubtypeAsUnknownVariant() throws {
    let chord = try parseChord("""
    <durationType>quarter</durationType>
    <Articulation><subtype>articSoftAccentAbove</subtype></Articulation>
    <Note><pitch>60</pitch><tpc>14</tpc></Note>
    """)
    #expect(chord.articulations == [
        ChordArticulation(kind: .unknown(subtype: "articSoftAccentAbove")),
    ])
}
```

Also update `encodeDecodeRoundTripsAllKinds` and `encodesUnknownVerbatim` in the same file: replace their `articAccentAbove` literals with `articSoftAccentAbove` (same rationale — the SymId must remain out-of-scope to exercise the `.unknown(...)` path).

Re-run: `swift test --filter ChordArticulationTests` — expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicCore/Score/ChordArticulation.swift \
        Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift \
        Tests/SheetMusicTests/ChordArticulationVelocityTests.swift \
        Tests/SheetMusicTests/ChordArticulationTests.swift
git commit -m "feat(core): accent / marcato / combined articulation kinds + MSCX round-trip"
```

---

### Task 2: MIDI — `effectiveVelocityScale` helper (MAX aggregate)

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` (add helper near `effectiveGateTime` at lines 281–309)
- Test (new): `Tests/SheetMusicTests/MidiRendererVelocityArticulationTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SheetMusicTests/MidiRendererVelocityArticulationTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiRendererVelocityArticulationTests {
    private let bareInstrument = Instrument(
        id: "test",
        articulations: [InstrumentArticulation(name: nil, velocity: 100, gateTime: 95)]
    )

    private func chord(_ kinds: [ChordArticulation.Kind]) -> Chord {
        Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: kinds.map { ChordArticulation(kind: $0) }
        )
    }

    @Test func noVelocityArticulationFallsBackToInstrumentDefault() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([]), instrument: bareInstrument
        )
        #expect(scale == 100) // unnamed-default preset value
    }

    @Test func accentUsesHardcodedFallbackWhenPresetMissing() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.accent]), instrument: bareInstrument
        )
        #expect(scale == 120)
    }

    @Test func accentUsesInstrumentPresetWhenPresent() {
        let inst = Instrument(
            id: "test",
            articulations: [
                InstrumentArticulation(name: nil, velocity: 100, gateTime: 95),
                InstrumentArticulation(name: "accent", velocity: 140, gateTime: 100),
            ]
        )
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.accent]), instrument: inst
        )
        #expect(scale == 140)
    }

    @Test func marcatoDefaultsToOneTwenty() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.marcato]), instrument: bareInstrument
        )
        #expect(scale == 120)
    }

    @Test func combinedKindsUseAccentOrMarcatoPreset() {
        let scale1 = MidiRenderer.effectiveVelocityScale(
            for: chord([.accentStaccato]), instrument: bareInstrument
        )
        let scale2 = MidiRenderer.effectiveVelocityScale(
            for: chord([.marcatoStaccato]), instrument: bareInstrument
        )
        #expect(scale1 == 120)
        #expect(scale2 == 120)
    }

    @Test func multipleVelocityArticulationsTakeMaximum() {
        // accent (120) + marcato (overridden to 130) → 130 wins.
        let inst = Instrument(
            id: "test",
            articulations: [
                InstrumentArticulation(name: nil, velocity: 100, gateTime: 95),
                InstrumentArticulation(name: "marcato", velocity: 130, gateTime: 100),
            ]
        )
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.accent, .marcato]), instrument: inst
        )
        #expect(scale == 130)
    }

    @Test func durationOnlyArticulationsAreIgnoredForVelocity() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.staccato, .tenuto]), instrument: bareInstrument
        )
        // No velocity-shaping kind present → fall back to default.
        #expect(scale == 100)
    }

    @Test func unknownArticulationFallsThroughToInstrumentDefault() {
        let c = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [.init(kind: .unknown(subtype: "articSoftAccentAbove"))]
        )
        let scale = MidiRenderer.effectiveVelocityScale(
            for: c, instrument: bareInstrument
        )
        #expect(scale == 100)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MidiRendererVelocityArticulationTests`
Expected: compile error — "type `MidiRenderer` has no member `effectiveVelocityScale`".

- [ ] **Step 3: Implement `effectiveVelocityScale`**

In `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`, immediately after the closing `}` of `effectiveGateTime(for:instrument:)` (line 309) and before the closing `}` of the `extension MidiRenderer { ... }` block (line 310), insert:

```swift
    /// Per-chord velocity-scale lookup. Filters `chord.articulations`
    /// to the in-scope velocity-shaping kinds (accent / marcato /
    /// accentStaccato / marcatoStaccato), looks each up in the
    /// instrument preset table, and returns the **maximum** velocity %
    /// among the candidates (matches MuseScore's
    /// `MidiArticulation::aggregateOf` — loudest wins). When no
    /// in-scope articulation is present, falls through to
    /// `defaultArticulationVelocityScale(for:)` so existing behaviour
    /// is preserved. C++:
    ///   engraving/compat/midi/compatmidirender.cpp
    ///   `CompatMidiRender::collectMeasureEvents` — articulation velocity.
    static func effectiveVelocityScale(for chord: Chord, instrument: Instrument) -> Int {
        let scales = chord.articulations.compactMap { art -> Int? in
            let presetName: String
            let hardcodedDefault: Int
            switch art.kind {
            case .accent, .accentStaccato:
                presetName = "accent"; hardcodedDefault = 120
            case .marcato, .marcatoStaccato:
                presetName = "marcato"; hardcodedDefault = 120
            case .staccato, .staccatissimo, .tenuto, .unknown:
                return nil
            }
            return instrument.articulations
                .first(where: { $0.name == presetName })?
                .velocity ?? hardcodedDefault
        }
        if let maximum = scales.max() {
            return maximum
        }
        return defaultArticulationVelocityScale(for: instrument)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MidiRendererVelocityArticulationTests`
Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift \
        Tests/SheetMusicTests/MidiRendererVelocityArticulationTests.swift
git commit -m "feat(midi): effectiveVelocityScale per-chord MAX aggregate"
```

---

### Task 3: MIDI — extend `effectiveGateTime` for combined kinds

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` (the inner `switch art.kind` of `effectiveGateTime`, lines 295–300)
- Modify (extend): `Tests/SheetMusicTests/MidiRendererVelocityArticulationTests.swift`

- [ ] **Step 1: Add failing tests**

Append to the `MidiRendererVelocityArticulationTests` suite:

```swift
@Test func combinedKindContributesStaccatoGateTime() {
    let gate = MidiRenderer.effectiveGateTime(
        for: chord([.accentStaccato]), instrument: bareInstrument
    )
    #expect(gate == 50)
}

@Test func marcatoStaccatoCombinedAlsoShortens() {
    let gate = MidiRenderer.effectiveGateTime(
        for: chord([.marcatoStaccato]), instrument: bareInstrument
    )
    #expect(gate == 50)
}

@Test func combinedAndPlainStaccatoYieldSameGateTime() {
    let combined = MidiRenderer.effectiveGateTime(
        for: chord([.accentStaccato]), instrument: bareInstrument
    )
    let plain = MidiRenderer.effectiveGateTime(
        for: chord([.accent, .staccato]), instrument: bareInstrument
    )
    #expect(combined == plain)
    #expect(combined == 50)
}

@Test func plainAccentDoesNotShortenGateTime() {
    let gate = MidiRenderer.effectiveGateTime(
        for: chord([.accent]), instrument: bareInstrument
    )
    // No duration-shaping kind in the chord → fall back to instrument default (95).
    #expect(gate == 95)
}

@Test func plainMarcatoDoesNotShortenGateTime() {
    let gate = MidiRenderer.effectiveGateTime(
        for: chord([.marcato]), instrument: bareInstrument
    )
    #expect(gate == 95)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MidiRendererVelocityArticulationTests`
Expected: 5 new tests fail with compile error — "type `ChordArticulation.Kind` switch is exhaustive but `effectiveGateTime` doesn't handle `.accent`/`.marcato`/`.accentStaccato`/`.marcatoStaccato`" — or, if Swift is permissive about the switch, runtime failures because the new cases collapse to the default (`fallback to instrument default`) producing the wrong gate values.

- [ ] **Step 3: Extend the `effectiveGateTime` switch**

In `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`, locate the inner `switch art.kind` of `effectiveGateTime` (currently:

```swift
switch art.kind {
case .staccato: presetName = "staccato"; hardcodedDefault = 50
case .staccatissimo: presetName = "staccatissimo"; hardcodedDefault = 33
case .tenuto: presetName = "tenuto"; hardcodedDefault = 100
case .unknown: return nil
}
```

Replace with:

```swift
switch art.kind {
case .staccato: presetName = "staccato"; hardcodedDefault = 50
case .staccatissimo: presetName = "staccatissimo"; hardcodedDefault = 33
case .tenuto: presetName = "tenuto"; hardcodedDefault = 100
case .accentStaccato, .marcatoStaccato:
    // Combined SymIds shorten via the existing "staccato" preset so that
    // [.accentStaccato] and [.accent, .staccato] produce identical gateTime.
    presetName = "staccato"; hardcodedDefault = 50
case .accent, .marcato, .unknown:
    return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MidiRendererVelocityArticulationTests`
Expected: all (8 + 5 = 13) tests PASS.

Run: `swift test --filter MidiRendererArticulationTests`
Expected: existing tests still PASS (no regression on staccato / staccatissimo / tenuto / unknown paths).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift \
        Tests/SheetMusicTests/MidiRendererVelocityArticulationTests.swift
git commit -m "feat(midi): combined accent-/marcato-staccato gateTime shortening"
```

---

### Task 4: MIDI — wire `adjustVelocityForChord` into `renderChordWithGraces`

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` (add helper near `effectiveVelocityScale`)
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift` (lines 79–238 — the `renderChordWithGraces` body)
- Modify (extend): `Tests/SheetMusicTests/MidiRendererVelocityArticulationTests.swift`

- [ ] **Step 1: Add failing end-to-end render tests**

Append to the `MidiRendererVelocityArticulationTests` suite. These reuse the `renderSingleChord` / `gateTicks` helpers from the existing `MidiRendererArticulationTests` — copy them inline so the new file is self-contained:

```swift
private func renderSingleChord(
    _ chord: Chord,
    division: Int = 480,
    instrument: Instrument = Instrument(id: "test")
) throws -> [TimedMidiEvent] {
    let voice = Voice(elements: [.chord(chord)])
    let measure = Measure(voices: [voice])
    let staff = Staff(measures: [measure])
    let part = Part(id: "P1", instrument: instrument, staves: [staff])
    let score = Score(division: division, parts: [part])
    let file = try MidiRenderer.render(score: score)
    return try #require(file.tracks.first).events
}

private func firstNoteOnVelocity(_ events: [TimedMidiEvent]) -> Int {
    for e in events {
        if case let .noteOn(_, _, v) = e.event, v > 0 { return v }
    }
    return -1
}

private func gateTicks(from events: [TimedMidiEvent]) -> Int {
    guard let on = events.first(where: {
        if case let .noteOn(_, _, v) = $0.event { return v > 0 }
        return false
    }) else { return -1 }
    guard let off = events.first(where: {
        if case .noteOff = $0.event { return true }
        if case let .noteOn(_, _, v) = $0.event { return v == 0 }
        return false
    }) else { return -1 }
    return off.tick - on.tick + 1
}

@Test func endToEndAccentBoostsVelocity() throws {
    // Default running velocity = mf (80). accent scale = 120%.
    // 80 * 120 / 100 = 96.
    let events = try renderSingleChord(chord([.accent]))
    #expect(firstNoteOnVelocity(events) == 96)
}

@Test func endToEndMarcatoBoostsVelocity() throws {
    let events = try renderSingleChord(chord([.marcato]))
    #expect(firstNoteOnVelocity(events) == 96)
}

@Test func endToEndAccentStaccatoBoostsVelocityAndShortens() throws {
    let events = try renderSingleChord(chord([.accentStaccato]))
    #expect(firstNoteOnVelocity(events) == 96)
    #expect(gateTicks(from: events) == 240) // 480 * 50%
}

@Test func endToEndMarcatoStaccatoBoostsVelocityAndShortens() throws {
    let events = try renderSingleChord(chord([.marcatoStaccato]))
    #expect(firstNoteOnVelocity(events) == 96)
    #expect(gateTicks(from: events) == 240)
}

@Test func endToEndPlainAccentDoesNotShortenGate() throws {
    let events = try renderSingleChord(chord([.accent]))
    #expect(gateTicks(from: events) == 480) // full quarter
}

@Test func endToEndCombinedAndSplitMatchExactly() throws {
    let combined = try renderSingleChord(chord([.accentStaccato]))
    let split = try renderSingleChord(chord([.accent, .staccato]))
    #expect(firstNoteOnVelocity(combined) == firstNoteOnVelocity(split))
    #expect(gateTicks(from: combined) == gateTicks(from: split))
}

@Test func endToEndNoVelocityArticulationKeepsRunningVelocity() throws {
    let events = try renderSingleChord(chord([.staccato]))
    // No velocity-shaping articulation → mf (80) untouched.
    #expect(firstNoteOnVelocity(events) == 80)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MidiRendererVelocityArticulationTests`
Expected: the 7 new end-to-end tests FAIL — `firstNoteOnVelocity == 80` for all (the boost has not been wired yet).

- [ ] **Step 3: Add `adjustVelocityForChord` helper**

In `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`, immediately after `effectiveVelocityScale(for:instrument:)`, add:

```swift
    /// Apply per-chord velocity scaling on top of the running voice
    /// velocity. `baseVelocity` already has the **default** articulation
    /// scale baked in (set by `effectiveVelocity` at voice setup /
    /// Dynamic events); the modifier swaps that default scale for the
    /// chord-effective scale via `base * eff / def`. Returns
    /// `baseVelocity` unchanged when the chord has no velocity-shaping
    /// articulation, so existing playback for unarticulated chords is
    /// bit-identical.
    static func adjustVelocityForChord(
        baseVelocity: Int,
        chord: Chord,
        instrument: Instrument
    ) -> Int {
        let defaultScale = defaultArticulationVelocityScale(for: instrument)
        let effectiveScale = effectiveVelocityScale(for: chord, instrument: instrument)
        if defaultScale == effectiveScale { return baseVelocity }
        return min(127, max(1, baseVelocity * effectiveScale / defaultScale))
    }
```

- [ ] **Step 4: Wire into `renderChordWithGraces`**

In `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift`, inside `renderChordWithGraces`, immediately after the line `let mainOff = mainOnset + gatedTicks - 1` (currently line 175), add:

```swift
        let mainVelocity = adjustVelocityForChord(
            baseVelocity: velocity,
            chord: chord,
            instrument: instrument
        )
```

Then in the **arpeggio branch** (currently line 194 region), change:

```swift
emitNoteEventsForGrace(
    note: note, channel: channel, velocity: velocity,
    onTick: onTick, offTick: offTick, events: &events
)
```

to:

```swift
emitNoteEventsForGrace(
    note: note, channel: channel, velocity: mainVelocity,
    onTick: onTick, offTick: offTick, events: &events
)
```

In the **non-arpeggio branch** (currently lines 200–212), change both inner emission calls so they pass `mainVelocity` instead of `velocity`:

```swift
} else {
    for note in chord.notes {
        if let glissando = note.glissando, let endPitch = glissandoEndPitch {
            renderGlissandoNote(
                note: note, glissando: glissando, endPitch: endPitch,
                startTick: mainOnset, durationTicks: playedTicks,
                velocity: mainVelocity, channel: channel,
                currentKey: currentKey, events: &events
            )
        } else {
            emitNoteEventsForGrace(
                note: note, channel: channel, velocity: mainVelocity,
                onTick: mainOnset, offTick: mainOff, events: &events
            )
        }
    }
}
```

Leave the **before-graces** loop (line 152 region) and the **after-graces** loop (line 226 region) using the unmodified `velocity` parameter.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MidiRendererVelocityArticulationTests`
Expected: all 7 new + earlier 13 tests PASS.

Run the broader MIDI suite to confirm no regression:

```
swift test --filter MidiRendererArticulationTests
swift test --filter MidiRendererTests
swift test --filter MidiExportTests
```

Expected: all PASS. Existing scores have no in-scope velocity-shaping articulations, so `adjustVelocityForChord` is a no-op (`defaultScale == effectiveScale`).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift \
        Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift \
        Tests/SheetMusicTests/MidiRendererVelocityArticulationTests.swift
git commit -m "feat(midi): per-chord velocity boost in renderChordWithGraces (main notes only)"
```

---

### Task 5: Layout — extend `ArticulationKind` + emitter mapping

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift` (the `ArticulationKind` enum at lines 195–199)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` (`renderableArticulationKind` switch at lines 1320–1329)
- Test (new): `Tests/SheetMusicTests/LayoutVelocityArticulationTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SheetMusicTests/LayoutVelocityArticulationTests.swift`:

```swift
import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutEngine velocity-shaping articulation emission")
struct LayoutVelocityArticulationTests {
    private static func score(
        articulations: [ChordArticulation]
    ) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([note]),
            articulations: articulations
        )
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure])
        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [staff]
            )]
        )
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func laidOut(_ s: Score) -> LayoutDocument {
        let opts = ScoreViewOptions(
            staffSize: 28, systemGap: 40, wrapToViewWidth: false
        )
        let natW = LayoutEngine.naturalContentWidth(score: s, options: opts)
        return LayoutEngine.layout(
            score: s, options: opts, availableWidth: natW
        )
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func articulationKinds(in doc: LayoutDocument) -> [LayoutElement.ArticulationKind] {
        guard let measure = doc.systems.first?.measures.first
        else { return [] }
        return measure.elements.compactMap { el in
            if case let .articulation(kind, _, _) = el { return kind }
            return nil
        }
    }

    @Test("Accent above emits one .articulation of kind .accent")
    func accentAbove() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            articulations: [.init(kind: .accent, anchor: .above)]
        ))
        #expect(Self.articulationKinds(in: doc) == [.accent])
    }

    @Test("Marcato below emits one .articulation of kind .marcato")
    func marcatoBelow() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            articulations: [.init(kind: .marcato, anchor: .below)]
        ))
        #expect(Self.articulationKinds(in: doc) == [.marcato])
    }

    @Test("Combined accent-staccato emits ONE .articulation, not two")
    func combinedSingleEntry() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            articulations: [.init(kind: .accentStaccato, anchor: .below)]
        ))
        #expect(Self.articulationKinds(in: doc) == [.accentStaccato])
    }

    @Test("Combined marcato-staccato also single entry")
    func combinedMarcatoSingleEntry() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            articulations: [.init(kind: .marcatoStaccato, anchor: .above)]
        ))
        #expect(Self.articulationKinds(in: doc) == [.marcatoStaccato])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LayoutVelocityArticulationTests`
Expected: compile error — "type `LayoutElement.ArticulationKind` has no case `accent`" (and the other three).

- [ ] **Step 3: Extend `ArticulationKind`**

In `Sources/SheetMusicLayout/Layout/LayoutElement.swift`, replace the `ArticulationKind` enum body (currently lines 195–199):

```swift
public enum ArticulationKind: Sendable, Equatable {
    case staccato
    case staccatissimo
    case tenuto
    case accent
    case marcato
    case accentStaccato
    case marcatoStaccato
}
```

- [ ] **Step 4: Extend `renderableArticulationKind`**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`, replace the `renderableArticulationKind` body (currently lines 1320–1329):

```swift
static func renderableArticulationKind(
    _ kind: ChordArticulation.Kind
) -> LayoutElement.ArticulationKind? {
    switch kind {
    case .staccato: .staccato
    case .staccatissimo: .staccatissimo
    case .tenuto: .tenuto
    case .accent: .accent
    case .marcato: .marcato
    case .accentStaccato: .accentStaccato
    case .marcatoStaccato: .marcatoStaccato
    case .unknown: nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LayoutVelocityArticulationTests`
Expected: all 4 tests PASS.

Run: `swift test --filter LayoutArticulationTests`
Expected: existing tests still PASS.

- [ ] **Step 6: Build the whole package to surface any non-exhaustive switches**

Run: `swift build`
Expected: clean build. If a renderer or other site has a `switch` over `LayoutElement.ArticulationKind` with no `default`, the compiler will flag it — handle the new four cases there. (No such site is expected: the only switch on `ArticulationKind` known at spec time is in `ArticulationRenderer.glyph`, which we extend in Task 6.)

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutElement.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift \
        Tests/SheetMusicTests/LayoutVelocityArticulationTests.swift
git commit -m "feat(layout): emit accent / marcato / combined LayoutElement.articulation"
```

---

### Task 6: Glyphs — SMuFLGlyph codepoints + ArticulationRenderer mapping

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift` (Articulations section starting line 93)
- Modify: `Sources/SheetMusicUI/Rendering/ArticulationRenderer.swift` (the `glyph(kind:isAbove:)` switch, lines 11–23)
- Test (extend): `Tests/SheetMusicTests/LayoutVelocityArticulationTests.swift`

- [ ] **Step 1: Update the test-file imports**

Edit the import block at the top of `Tests/SheetMusicTests/LayoutVelocityArticulationTests.swift` so it includes `@testable import SheetMusicUI` (needed because `ArticulationRenderer.glyph(...)` is internal to the UI module):

```swift
import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicUI
import Testing
```

- [ ] **Step 2: Add a glyph-mapping test**

Append to the `LayoutVelocityArticulationTests` suite:

```swift
@Test("Glyph mapping for the eight new (kind, isAbove) pairs")
func glyphMapping() throws {
    guard #available(macOS 15.0, iOS 16.0, *) else { return }
    let cases: [(LayoutElement.ArticulationKind, Bool, Character)] = [
        (.accent, true, "\u{E4A0}"),
        (.accent, false, "\u{E4A1}"),
        (.marcato, true, "\u{E4AC}"),
        (.marcato, false, "\u{E4AD}"),
        (.accentStaccato, true, "\u{E4B0}"),
        (.accentStaccato, false, "\u{E4B1}"),
        (.marcatoStaccato, true, "\u{E4AE}"),
        (.marcatoStaccato, false, "\u{E4AF}"),
    ]
    for (kind, isAbove, expected) in cases {
        #expect(
            ArticulationRenderer.glyph(kind: kind, isAbove: isAbove) == expected,
            "kind=\(kind) isAbove=\(isAbove)"
        )
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter LayoutVelocityArticulationTests/glyphMapping`
Expected: compile error — switch in `ArticulationRenderer.glyph` is non-exhaustive (the new `LayoutElement.ArticulationKind` cases from Task 5 aren't handled).

- [ ] **Step 4: Add the eight SMuFLGlyph codepoints**

In `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift`, in the "Articulations" block (currently lines 97–102), append:

```swift
static let articAccentAbove: Character = "\u{E4A0}"
static let articAccentBelow: Character = "\u{E4A1}"
static let articMarcatoAbove: Character = "\u{E4AC}"
static let articMarcatoBelow: Character = "\u{E4AD}"
static let articAccentStaccatoAbove: Character = "\u{E4B0}"
static let articAccentStaccatoBelow: Character = "\u{E4B1}"
static let articMarcatoStaccatoAbove: Character = "\u{E4AE}"
static let articMarcatoStaccatoBelow: Character = "\u{E4AF}"
```

- [ ] **Step 5: Extend `ArticulationRenderer.glyph`**

In `Sources/SheetMusicUI/Rendering/ArticulationRenderer.swift`, replace the inner `switch (kind, isAbove)` body (currently lines 15–22) with:

```swift
switch (kind, isAbove) {
case (.staccato, true): return SMuFLGlyph.articStaccatoAbove
case (.staccato, false): return SMuFLGlyph.articStaccatoBelow
case (.staccatissimo, true): return SMuFLGlyph.articStaccatissimoAbove
case (.staccatissimo, false): return SMuFLGlyph.articStaccatissimoBelow
case (.tenuto, true): return SMuFLGlyph.articTenutoAbove
case (.tenuto, false): return SMuFLGlyph.articTenutoBelow
case (.accent, true): return SMuFLGlyph.articAccentAbove
case (.accent, false): return SMuFLGlyph.articAccentBelow
case (.marcato, true): return SMuFLGlyph.articMarcatoAbove
case (.marcato, false): return SMuFLGlyph.articMarcatoBelow
case (.accentStaccato, true): return SMuFLGlyph.articAccentStaccatoAbove
case (.accentStaccato, false): return SMuFLGlyph.articAccentStaccatoBelow
case (.marcatoStaccato, true): return SMuFLGlyph.articMarcatoStaccatoAbove
case (.marcatoStaccato, false): return SMuFLGlyph.articMarcatoStaccatoBelow
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter LayoutVelocityArticulationTests`
Expected: all 5 tests PASS.

Run: `swift build`
Expected: clean build (the `glyph` switch is now exhaustive over the extended `ArticulationKind`).

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift \
        Sources/SheetMusicUI/Rendering/ArticulationRenderer.swift \
        Tests/SheetMusicTests/LayoutVelocityArticulationTests.swift
git commit -m "feat(ui): SMuFL glyphs for accent / marcato / combined articulations"
```

---

### Task 7: ScoreLayerBuilder smoke for accent

**Files:**
- Modify: `Tests/SheetMusicTests/ScoreLayerBuilderTests.swift` (extend the existing accent-glyph smoke pattern from commit 336327a)

- [ ] **Step 1: Add a failing-or-passing smoke test**

In `Tests/SheetMusicTests/ScoreLayerBuilderTests.swift`, immediately after the existing `staccatoEmitsGlyphLayer` test, add:

```swift
@MainActor
@Test("Accent chord emits a glyph sublayer above the staff")
func accentEmitsGlyphLayer() throws {
    guard #available(macOS 15.0, *) else { return }
    _ = BravuraFont.register
    let chord = Chord(
        duration: .quarter,
        notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
        articulations: [.init(kind: .accent, anchor: .above)]
    )
    let staff = Staff(measures: [
        Measure(voices: [Voice(elements: [.chord(chord)])]),
    ])
    let score = Score(division: 480, parts: [
        Part(
            id: "1",
            instrument: Instrument(id: "x"),
            staves: [staff]
        ),
    ])
    let opts = ScoreViewOptions(
        staffSize: 28, systemGap: 40, wrapToViewWidth: false
    )
    let natW = LayoutEngine.naturalContentWidth(
        score: score, options: opts
    )
    let doc = LayoutEngine.layout(
        score: score, options: opts, availableWidth: natW
    )
    let system = try #require(doc.systems.first)
    let tree = ScoreLayerBuilder.buildSystem(
        system, metrics: doc.metrics
    )
    let sp = doc.metrics.sp
    let glyphLayers = collectAllLayers(tree)
        .compactMap { $0 as? CAShapeLayer }
        .filter { $0.fillColor != nil && $0.path != nil }
    // Accent glyph is wider than tall; require width > sp/2 and
    // bbox fits within ~1.5 sp on each side.
    let accent = glyphLayers.first { l in
        guard let p = l.path else { return false }
        let bb = p.boundingBoxOfPath
        return bb.width > sp * 0.5 && bb.width < sp * 1.5
            && bb.height > 0 && bb.height < sp * 1.5
    }
    #expect(
        accent != nil,
        "no accent-sized glyph layer found among \(glyphLayers.count) filled layers"
    )
}
```

- [ ] **Step 2: Run the smoke test**

Run: `swift test --filter ScoreLayerBuilderTests`
Expected: PASS. (Tasks 1, 5, and 6 already enabled accent end-to-end; this is a smoke confirming the CALayer pipeline produces a glyph in the right approximate bounding box.)

- [ ] **Step 3: Run the full suite once for confidence**

```bash
swift test
swiftlint --quiet Sources Tests
```

Expected: all tests pass; lint clean.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/ScoreLayerBuilderTests.swift
git commit -m "test(ui): smoke test accent glyph appears in CALayer pipeline"
```

---

## Manual visual verification (out of CI)

After Task 7, run the Mac example app to confirm placement looks correct against MuseScore's own rendering. Per project memory, visual checks use `SheetMusicExampleMac`, not the iOS Simulator.

1. Open or programmatically craft an `.mscx` containing a chord that carries each new kind (one of `.accent`, `.marcato`, `.accentStaccato`, `.marcatoStaccato`, with both `.above` and `.below` variants). The simplest path is to extend a `.mscx` test fixture in memory inside an example-app debug menu, or temporarily mutate `midi01.mscx` in place during the visual check session.
2. Run `SheetMusicExampleMac` (Xcode → SheetMusicExampleMac scheme → Run).
3. Compare the rendered glyphs against MuseScore opening the same `.mscx`. Glyph shape, side (above/below), and Y offset should match within a half-staff-space.
4. If the marcato gateTime issue noted in the spec's Risks section turns out to apply, adjust the hardcoded fallback in `effectiveGateTime` and add a regression test, then re-run the full suite.

## Self-review checklist (run after writing this plan)

- Spec coverage:
  - Decoder + 4 new mappings → Task 1
  - Encoder + 4 new mappings → Task 1
  - `effectiveVelocityScale` (MAX, accent/marcato/combined) → Task 2
  - `effectiveGateTime` extension for combined kinds → Task 3
  - `adjustVelocityForChord` per-chord modifier in `renderChordWithGraces` → Task 4
  - `LayoutElement.ArticulationKind` extension → Task 5
  - `renderableArticulationKind` extension → Task 5
  - SMuFLGlyph codepoints (8) → Task 6
  - `ArticulationRenderer.glyph` extension → Task 6
  - Layout emit / combined-as-one-glyph → Task 5 + Task 6
  - End-to-end MIDI tests → Task 4
  - Layer smoke → Task 7
- Type consistency: `effectiveVelocityScale` / `adjustVelocityForChord` introduced once in Task 2 / 4 and referenced verbatim afterward; `LayoutElement.ArticulationKind` cases match the Task 5 enum verbatim in Task 6 mapping.
- No placeholders.
