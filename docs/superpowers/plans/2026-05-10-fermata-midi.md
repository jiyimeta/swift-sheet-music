# Fermata MIDI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `.fermata` voice elements actually slow MIDI playback by inserting tempo bookends, mirroring MuseScore's `tempomapWithPauses` behaviour.

**Architecture:** Add `timeStretch: Double` to `Fermata` (with subtype defaults). Per-staff collect `[FermataRange]` (anchor each fermata to the chord/rest in its voice, dedupe identical (start,end) ranges). Pre-build a `TempoTimeline` from staff 0 / voice 0. Sweep-merge ranges into a step function of effective stretch and emit tempo meta events at every transition boundary. Insertion order at same tick is `close → score .tempo → open`, achieved by inserting close events before the voice walk and open events after — `renderTrack`'s existing stable sort preserves the order.

**Tech Stack:** Swift Package Manager, Swift Testing (`@Test`, `#expect`), `@testable import` of each sub-library.

**Spec:** `docs/superpowers/specs/2026-05-10-fermata-midi-design.md`

---

## File Structure

**Create:**

- `Sources/SheetMusicMIDI/Render/FermataRanges.swift` — `FermataRange` struct, `FermataRanges.collect(staff:division:)`, `TempoTimeline` struct, and `FermataRanges.tempoEvents(ranges:timeline:)` returning the partitioned `(closeEvents, openEvents)` for the renderer to splice in.
- `Tests/SheetMusicTests/FermataMidiTests.swift` — end-to-end MIDI render tests.

**Modify:**

- `Sources/SheetMusicCore/Score/Fermata.swift` — add `timeStretch` field + subtype default helper.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift` — parse `<timeStretch>`.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Fermata.swift` — emit `<timeStretch>` only when non-default.
- `Sources/SheetMusicMIDI/Render/MidiRenderer.swift` — in `renderTrack`, splice fermata close/open events around voice walks (achieves close → .tempo → open ordering via stable sort).
- `Tests/SheetMusicTests/MSCXEncoderTextElementsTests.swift` — extend `fermataRoundTrip` with timeStretch cases.

---

## Task 1: Add `timeStretch` field and subtype defaults to `Fermata`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Fermata.swift`
- Test: `Tests/SheetMusicTests/FermataModelTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/FermataModelTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
import Testing

@Suite struct FermataModelTests {
    @Test func subtypeDefaultsMatchMuseScore() {
        // Subtype → expected default timeStretch.
        let cases: [(String, Double)] = [
            ("fermataAbove", 1.5),
            ("fermataBelow", 1.5),
            ("fermataShortAbove", 1.5),
            ("fermataShortBelow", 1.5),
            ("fermataLongAbove", 2.0),
            ("fermataLongBelow", 2.0),
            ("fermataLongHenzeAbove", 2.0),
            ("fermataLongHenzeBelow", 2.0),
            ("fermataVeryLongAbove", 3.0),
            ("fermataVeryLongBelow", 3.0),
            ("fermataVeryShortAbove", 1.25),
            ("fermataVeryShortBelow", 1.25),
            ("fermataShortHenzeAbove", 1.25),
            ("fermataShortHenzeBelow", 1.25),
            ("unknownGlyphName", 1.5), // fail-safe default
        ]
        for (subtype, expected) in cases {
            let fermata = Fermata(subtype: subtype)
            #expect(fermata.timeStretch == expected, "subtype=\(subtype)")
        }
    }

    @Test func explicitTimeStretchOverridesDefault() {
        let fermata = Fermata(subtype: "fermataAbove", timeStretch: 2.5)
        #expect(fermata.timeStretch == 2.5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FermataModelTests -q`
Expected: FAIL — compile error because `Fermata` has no `timeStretch` field and no `init(subtype:timeStretch:)`.

- [ ] **Step 3: Update `Fermata` struct**

Replace the body of `Sources/SheetMusicCore/Score/Fermata.swift`:

```swift
import Foundation

/// A fermata symbol held above/below a chord or rest.
/// C++: `mu::engraving::Fermata`.
public struct Fermata: Sendable, Equatable {
    /// MuseScore `<subtype>` text (e.g. `fermataAbove`, `fermataBelow`,
    /// `fermataLongAbove`, …). Kept as a raw string because the full
    /// SMuFL-derived set is large and MuseScore 5.x extends it freely.
    public var subtype: String

    /// MIDI hold ratio. 1.0 = no stretch. MSCX `<timeStretch>` overrides
    /// the subtype default when present.
    /// C++: `mu::engraving::Fermata::timeStretch`.
    public var timeStretch: Double

    public init(subtype: String, timeStretch: Double? = nil) {
        self.subtype = subtype
        self.timeStretch = timeStretch ?? Self.defaultTimeStretch(for: subtype)
    }

    /// Subtype → default MIDI hold ratio. Mirrors MuseScore's
    /// per-symbol `Fermata::timeStretch` defaults.
    public static func defaultTimeStretch(for subtype: String) -> Double {
        switch subtype {
        case "fermataVeryShortAbove", "fermataVeryShortBelow",
             "fermataShortHenzeAbove", "fermataShortHenzeBelow":
            return 1.25
        case "fermataAbove", "fermataBelow",
             "fermataShortAbove", "fermataShortBelow":
            return 1.5
        case "fermataLongAbove", "fermataLongBelow",
             "fermataLongHenzeAbove", "fermataLongHenzeBelow":
            return 2.0
        case "fermataVeryLongAbove", "fermataVeryLongBelow":
            return 3.0
        default:
            return 1.5
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FermataModelTests -q`
Expected: PASS — both tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/Fermata.swift Tests/SheetMusicTests/FermataModelTests.swift
git commit -m "core: add Fermata.timeStretch with subtype defaults"
```

---

## Task 2: MSCX decoder parses `<timeStretch>`

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift:116-118`
- Test: `Tests/SheetMusicTests/FermataModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `FermataModelTests`:

```swift
    @Test func mscxDecodesExplicitTimeStretch() throws {
        let xml = """
        <voice>
          <Fermata>
            <subtype>fermataAbove</subtype>
            <timeStretch>2.5</timeStretch>
          </Fermata>
        </voice>
        """
        let voice = try Voice.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        guard case let .fermata(f) = voice.elements[0] else {
            Issue.record("element 0 is not a fermata"); return
        }
        #expect(f.subtype == "fermataAbove")
        #expect(f.timeStretch == 2.5)
    }

    @Test func mscxDecodeFallsBackToSubtypeDefault() throws {
        let xml = """
        <voice>
          <Fermata><subtype>fermataLongAbove</subtype></Fermata>
        </voice>
        """
        let voice = try Voice.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        guard case let .fermata(f) = voice.elements[0] else {
            Issue.record("element 0 is not a fermata"); return
        }
        #expect(f.timeStretch == 2.0) // long default
    }
```

Add the imports needed at the top of the file:

```swift
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FermataModelTests -q`
Expected: FAIL — explicit `<timeStretch>` returns the default 1.5 instead of 2.5.

- [ ] **Step 3: Update the MSCX decoder**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift`, replace the existing `case "Fermata":` block (currently lines 116-118):

```swift
            case "Fermata":
                let subtype = child.first("subtype")?.text ?? ""
                let stretch = child.first("timeStretch")?.text.flatMap(Double.init)
                elements.append(.fermata(Fermata(subtype: subtype, timeStretch: stretch)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FermataModelTests -q`
Expected: PASS — all four tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift Tests/SheetMusicTests/FermataModelTests.swift
git commit -m "mscx: decode <timeStretch> on Fermata"
```

---

## Task 3: MSCX encoder emits `<timeStretch>` when non-default

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Fermata.swift`
- Test: `Tests/SheetMusicTests/MSCXEncoderTextElementsTests.swift:139-149`

- [ ] **Step 1: Replace the existing `fermataRoundTrip` test**

In `Tests/SheetMusicTests/MSCXEncoderTextElementsTests.swift`, replace the `@Test("Fermata round-trips subtype")` block (currently lines 139-149) with the expanded version:

```swift
    @Test("Fermata round-trips subtype and explicit timeStretch")
    func fermataRoundTrip() throws {
        // (subtype, explicit timeStretch or nil → use default,
        //  expectedXMLContainsTimeStretch)
        let cases: [(String, Double?, Bool)] = [
            ("fermataAbove",      nil,  false),  // default 1.5 → omit
            ("fermataLongAbove",  nil,  false),  // default 2.0 → omit
            ("fermataAbove",      2.5,  true),   // override → emit
            ("fermataLongAbove",  2.0,  false),  // matches default → omit
            ("fermataAbove",      1.0,  true),   // override to 1.0 → emit
        ]
        for (subtype, stretch, expectXML) in cases {
            let voice = Voice(elements: [
                .chord(Chord(duration: .quarter,
                             notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
                .fermata(Fermata(subtype: subtype, timeStretch: stretch)),
            ])
            let encoded = try voiceRoundTripXMLString(voice)
            let hasTimeStretch = encoded.contains("<timeStretch>")
            #expect(
                hasTimeStretch == expectXML,
                "subtype=\(subtype) stretch=\(String(describing: stretch)) " +
                "expectedTimeStretchEmitted=\(expectXML)"
            )
            let decoded = try voiceRoundTrip(voice)
            #expect(decoded == voice,
                    "subtype=\(subtype) stretch=\(String(describing: stretch)) failed round-trip")
        }
    }
```

If the helper `voiceRoundTripXMLString` does not exist in this file, add it next to `voiceRoundTrip` — it should produce the encoded XML as a `String` for substring assertions. Find the existing `voiceRoundTrip` helper in the same file and add adjacent to it:

```swift
    /// Encodes the voice and returns the XML as a UTF-8 string so callers
    /// can assert on its contents (used by `fermataRoundTrip`).
    private func voiceRoundTripXMLString(_ voice: Voice) throws -> String {
        let node = voice.encode()
        let data = node.serialize()
        return String(data: data, encoding: .utf8) ?? ""
    }
```

If the existing helpers do not expose `voice.encode()` directly, mirror whatever serialization path `voiceRoundTrip` uses (read the helper first to confirm; the test target already has `@testable` access).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter fermataRoundTrip -q`
Expected: FAIL — encoded XML never contains `<timeStretch>` (encoder still emits subtype only).

- [ ] **Step 3: Update the MSCX encoder**

Replace the body of `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Fermata.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Fermata {
    /// Build a `<Fermata>` element. Mirrors the inline fermata
    /// decoding in `MSCXDecoder+Voice.swift`. `<timeStretch>` is
    /// omitted when the value matches the subtype's default — same
    /// "omit when default" convention MuseScore uses.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: subtype),
        ]
        let defaultStretch = Fermata.defaultTimeStretch(for: subtype)
        if timeStretch != defaultStretch {
            children.append(XMLTreeNode(
                name: "timeStretch",
                text: formatStretch(timeStretch)
            ))
        }
        return XMLTreeNode(name: "Fermata", children: children)
    }

    /// MuseScore writes whole numbers without a trailing `.0` and
    /// fractional values with a fixed precision; mimic that to keep
    /// MSCX diffs readable. Examples: 2.0 → "2", 1.25 → "1.25".
    private func formatStretch(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(value)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter fermataRoundTrip -q`
Expected: PASS — explicit timeStretch round-trips and the omit-when-default rule holds.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Fermata.swift Tests/SheetMusicTests/MSCXEncoderTextElementsTests.swift
git commit -m "mscx: emit <timeStretch> on Fermata only when non-default"
```

---

## Task 4: `FermataRange` struct + `FermataRanges.collect`

**Files:**
- Create: `Sources/SheetMusicMIDI/Render/FermataRanges.swift`
- Test: `Tests/SheetMusicTests/FermataRangesTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `Tests/SheetMusicTests/FermataRangesTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct FermataRangesTests {
    private func chord(_ pitch: Int = 60, _ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: 14)]))
    }
    private func rest(_ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: []))
    }
    private func fermata(_ subtype: String = "fermataAbove",
                        stretch: Double? = nil) -> VoiceElement {
        .fermata(Fermata(subtype: subtype, timeStretch: stretch))
    }
    private func staff(_ voiceElements: [[VoiceElement]]) -> Staff {
        // One measure, len = sum of first voice's chord durations.
        let voices = voiceElements.map { Voice(elements: $0) }
        return Staff(measures: [Measure(voices: voices)])
    }

    // MARK: anchor: forward search (canonical MusicXML layout)

    @Test func forwardAnchorPicksNextChord() {
        let s = staff([[
            chord(60),                                  // tick 0..480
            fermata("fermataAbove"),                    // anchors to D4
            chord(62),                                  // tick 480..960
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 480, endTick: 960, stretch: 1.5)])
    }

    @Test func forwardAnchorAcrossDynamicAndKeySig() {
        let s = staff([[
            chord(60),
            fermata("fermataAbove"),
            .dynamic(Dynamic(subtype: "mf")),           // skipped
            chord(62),
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 480, endTick: 960, stretch: 1.5)])
    }

    // MARK: anchor: backward fallback (MSCX after-chord layout)

    @Test func backwardFallbackPicksPreviousChord() {
        let s = staff([[
            chord(60),                                  // tick 0..480
            fermata("fermataAbove"),                    // no chord after → fall back to C4
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 1.5)])
    }

    // MARK: anchor: no chord → drop silently

    @Test func orphanFermataDropped() {
        let s = staff([[
            fermata("fermataAbove"),                    // no chord at all
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges.isEmpty)
    }

    // MARK: stretch: subtype default vs explicit

    @Test func longSubtypeUsesDefaultStretch() {
        let s = staff([[
            fermata("fermataLongAbove"),
            chord(60),
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 2.0)])
    }

    @Test func explicitStretchOverridesSubtypeDefault() {
        let s = staff([[
            fermata("fermataAbove", stretch: 2.5),
            chord(60),
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 2.5)])
    }

    // MARK: rest fermata applies (grand pause)

    @Test func restFermataYieldsRange() {
        let s = staff([[
            fermata("fermataAbove"),
            rest(.quarter),
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 1.5)])
    }

    // MARK: dedupe identical ranges across voices

    @Test func sameRangeAcrossVoicesDedupedToMaxStretch() {
        let s = staff([
            [fermata("fermataAbove"),     chord(60)],   // stretch 1.5 on [0,480)
            [fermata("fermataLongAbove"), chord(60)],   // stretch 2.0 on [0,480)
        ])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 2.0)])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FermataRangesTests -q`
Expected: FAIL — compile error because `FermataRanges` and `FermataRange` do not exist.

- [ ] **Step 3: Create `FermataRanges.swift` (collection only)**

Create `Sources/SheetMusicMIDI/Render/FermataRanges.swift`:

```swift
import Foundation
import SheetMusicCore

/// One resolved fermata: the original-tick range its anchor chord/rest
/// occupies, and the hold ratio to apply during that range.
struct FermataRange: Sendable, Equatable {
    let startTick: Int      // original (pre-repeat) tick
    let endTick: Int        // exclusive
    let stretch: Double     // ≥ 1.0
}

enum FermataRanges {
    /// Walk every voice, anchor each `.fermata` element to its target
    /// chord/rest, and return the per-staff range list. Deduped on
    /// identical (startTick, endTick) — max stretch wins.
    static func collect(from staff: Staff, division: Int) -> [FermataRange] {
        var ranges: [FermataRange] = []
        var measureBase = 0
        for measure in staff.measures {
            let mTicks = MidiRenderer.measureTicks(
                measure: measure, division: division
            )
            for voice in measure.voices {
                ranges.append(contentsOf: collectInVoice(
                    voice, measureBase: measureBase, division: division
                ))
            }
            measureBase += mTicks
        }
        return dedupeMaxStretch(ranges)
    }

    /// Per-voice anchor walk. Forward search from each fermata for the
    /// next chord/rest in the same voice; if none, fall back to the
    /// most recent prior chord/rest. Drop the fermata when neither
    /// direction yields one.
    private static func collectInVoice(
        _ voice: Voice,
        measureBase: Int,
        division: Int
    ) -> [FermataRange] {
        // Pre-compute each chord's start tick within the voice so both
        // forward and backward searches are O(1) lookups.
        var chordStartTicks: [Int?] = Array(
            repeating: nil, count: voice.elements.count
        )
        var runningTick = measureBase
        for (i, element) in voice.elements.enumerated() {
            switch element {
            case let .chord(chord):
                chordStartTicks[i] = runningTick
                runningTick += chord.duration.ticks(division: division)
            case let .locationShift(delta):
                runningTick += delta.ticks(division: division)
            default:
                break
            }
        }

        var ranges: [FermataRange] = []
        for (i, element) in voice.elements.enumerated() {
            guard case let .fermata(f) = element else { continue }
            let anchor = anchorForFermata(at: i, in: voice, chordStartTicks: chordStartTicks)
            guard let anchor else { continue }
            let chordTicks = anchor.chord.duration.ticks(division: division)
            ranges.append(FermataRange(
                startTick: anchor.startTick,
                endTick: anchor.startTick + chordTicks,
                stretch: f.timeStretch
            ))
        }
        return ranges
    }

    private struct Anchor { let chord: Chord; let startTick: Int }

    private static func anchorForFermata(
        at index: Int,
        in voice: Voice,
        chordStartTicks: [Int?]
    ) -> Anchor? {
        // Forward search.
        for j in (index + 1) ..< voice.elements.count {
            if case let .chord(chord) = voice.elements[j],
               let start = chordStartTicks[j] {
                return Anchor(chord: chord, startTick: start)
            }
        }
        // Backward fallback.
        if index > 0 {
            for j in stride(from: index - 1, through: 0, by: -1) {
                if case let .chord(chord) = voice.elements[j],
                   let start = chordStartTicks[j] {
                    return Anchor(chord: chord, startTick: start)
                }
            }
        }
        return nil
    }

    /// Group by (startTick, endTick); within each group keep the
    /// largest stretch. Returns ranges sorted by startTick then
    /// endTick — required by the sweep-merge consumer.
    private static func dedupeMaxStretch(_ ranges: [FermataRange]) -> [FermataRange] {
        var bestByKey: [String: FermataRange] = [:]
        for r in ranges {
            let key = "\(r.startTick)-\(r.endTick)"
            if let prev = bestByKey[key], prev.stretch >= r.stretch { continue }
            bestByKey[key] = r
        }
        return bestByKey.values.sorted { lhs, rhs in
            (lhs.startTick, lhs.endTick) < (rhs.startTick, rhs.endTick)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FermataRangesTests -q`
Expected: PASS — all seven anchor / stretch / dedupe tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/FermataRanges.swift Tests/SheetMusicTests/FermataRangesTests.swift
git commit -m "midi: collect FermataRange list per staff with anchor + dedupe"
```

---

## Task 5: `TempoTimeline` and sweep-merge → tempo events

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/FermataRanges.swift`
- Test: `Tests/SheetMusicTests/FermataRangesTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `FermataRangesTests`:

```swift
    // MARK: TempoTimeline lookup

    @Test func tempoTimelineLookupPicksLastEntryAtOrBeforeTick() {
        let timeline = TempoTimeline(entries: [
            (tick: 0,    bps: 2.0),       // 120 BPM
            (tick: 480,  bps: 3.0),       // 180 BPM
            (tick: 1920, bps: 1.5),       // 90 BPM
        ])
        #expect(timeline.bps(at: 0)    == 2.0)
        #expect(timeline.bps(at: 200)  == 2.0)
        #expect(timeline.bps(at: 480)  == 3.0)
        #expect(timeline.bps(at: 1000) == 3.0)
        #expect(timeline.bps(at: 1920) == 1.5)
        #expect(timeline.bps(at: 9999) == 1.5)
    }

    @Test func tempoTimelineDefaultIsTwoBps() {
        let timeline = TempoTimeline.build(from: Staff(measures: [Measure(voices: [Voice(elements: [
            chord(60),
        ])])]), division: 480)
        #expect(timeline.bps(at: 0) == 2.0)
        #expect(timeline.bps(at: 1000) == 2.0)
    }

    @Test func tempoTimelinePicksUpFromVoiceZero() {
        let staff = Staff(measures: [Measure(voices: [Voice(elements: [
            chord(60),                          // 0..480
            .tempo(Tempo(beatsPerSecond: 3.0)), // change at tick 480
            chord(62),                          // 480..960
        ])])])
        let timeline = TempoTimeline.build(from: staff, division: 480)
        #expect(timeline.bps(at: 0)   == 2.0)
        #expect(timeline.bps(at: 479) == 2.0)
        #expect(timeline.bps(at: 480) == 3.0)
        #expect(timeline.bps(at: 800) == 3.0)
    }

    // MARK: sweep-merge tempo events

    @Test func singleRangeProducesOpenAndClosePair() {
        let ranges = [FermataRange(startTick: 480, endTick: 960, stretch: 1.5)]
        let timeline = TempoTimeline(entries: [(tick: 0, bps: 2.0)])
        let result = FermataRanges.tempoEvents(ranges: ranges, timeline: timeline)
        #expect(result.openEvents.map(eventSpec) == [
            (480, microsForBpm(120 / 1.5)),
        ])
        #expect(result.closeEvents.map(eventSpec) == [
            (960, microsForBpm(120)),
        ])
    }

    @Test func partialOverlapEmitsThreeRegions() {
        // Range A: [0, 720)  stretch 2.0  (dotted-quarter)
        // Range B: [0, 480)  stretch 1.5  (quarter, shorter)
        // Expected timeline: [0,480) max=2.0, [480,720) max=2.0 (A still on),
        //   [720, ∞) restored. Wait — B ends sooner (480), so:
        //   [0,480)  active={2.0,1.5} → 2.0
        //   [480,720) active={2.0}    → 2.0  (no transition; merge into prev)
        //   [720, ∞)  active={}       → 1.0 restore
        // Sweep-merge should drop the redundant 480 boundary.
        let ranges = [
            FermataRange(startTick: 0, endTick: 720, stretch: 2.0),
            FermataRange(startTick: 0, endTick: 480, stretch: 1.5),
        ]
        let timeline = TempoTimeline(entries: [(tick: 0, bps: 2.0)])
        let result = FermataRanges.tempoEvents(ranges: ranges, timeline: timeline)
        #expect(result.openEvents.map(eventSpec) == [
            (0, microsForBpm(120 / 2.0)), // 60 BPM
        ])
        #expect(result.closeEvents.map(eventSpec) == [
            (720, microsForBpm(120)),
        ])
    }

    @Test func partialOverlapWithDifferentEndsEmitsStaircase() {
        // Range A: [0, 480)  stretch 2.0
        // Range B: [240, 720) stretch 1.5
        // Sweep:
        //   [0, 240)   active={A=2.0}        → 2.0
        //   [240, 480) active={A=2.0,B=1.5}  → 2.0  (no change; merge)
        //   [480, 720) active={B=1.5}        → 1.5
        //   [720, ∞)   active={}             → 1.0
        // Expected open at 0 (60BPM) and at 480 (80BPM); close at 720 (120BPM).
        let ranges = [
            FermataRange(startTick: 0,   endTick: 480, stretch: 2.0),
            FermataRange(startTick: 240, endTick: 720, stretch: 1.5),
        ]
        let timeline = TempoTimeline(entries: [(tick: 0, bps: 2.0)])
        let result = FermataRanges.tempoEvents(ranges: ranges, timeline: timeline)
        #expect(result.openEvents.map(eventSpec) == [
            (0,   microsForBpm(60)),  // 120/2.0
            (480, microsForBpm(80)),  // 120/1.5
        ])
        #expect(result.closeEvents.map(eventSpec) == [
            (720, microsForBpm(120)),
        ])
    }

    @Test func boundaryTempoChangeDrivesPostFermataValue() {
        // Fermata: [0, 480) stretch 2.0; .tempo(180 BPM) lands at tick 480.
        // Open at 0 reads base bps via timeline.bps(at: 0) = 2.0 → 60 BPM.
        // Close at 480 reads timeline.bps(at: 480) = 3.0 → 180 BPM.
        let ranges = [FermataRange(startTick: 0, endTick: 480, stretch: 2.0)]
        let timeline = TempoTimeline(entries: [
            (tick: 0,   bps: 2.0),
            (tick: 480, bps: 3.0),
        ])
        let result = FermataRanges.tempoEvents(ranges: ranges, timeline: timeline)
        #expect(result.openEvents.map(eventSpec) == [
            (0, microsForBpm(60)),
        ])
        #expect(result.closeEvents.map(eventSpec) == [
            (480, microsForBpm(180)),
        ])
    }

    // MARK: - Helpers used in this section

    private func eventSpec(_ event: TimedMidiEvent) -> (Int, Int) {
        guard case let .meta(.tempo(micros)) = event.event else {
            Issue.record("expected tempo meta, got \(event.event)")
            return (event.tick, -1)
        }
        return (event.tick, micros)
    }

    private func microsForBpm(_ bpm: Double) -> Int {
        // micros per quarter = 60_000_000 / BPM
        return Int((60_000_000.0 / bpm).rounded())
    }
```

(NOTE: The `microsForBpm` helper above mirrors the standard SMF tempo conversion. Adjust the rounding if `Tempo.microsecondsPerQuarter` rounds differently — the implementation must use the same rounding so the spec values match exactly.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FermataRangesTests -q`
Expected: FAIL — `TempoTimeline`, `TempoTimeline.build`, and `FermataRanges.tempoEvents` are not defined.

- [ ] **Step 3: Add `TempoTimeline` and `tempoEvents` to FermataRanges.swift**

Append to `Sources/SheetMusicMIDI/Render/FermataRanges.swift`:

```swift
/// Sorted (tick, beats-per-second) checkpoints. Lookup returns the
/// last entry whose tick is ≤ the queried tick. Defaults to a single
/// `(0, 2.0)` entry (= 120 BPM, MuseScore default) so empty scores
/// still answer correctly.
struct TempoTimeline: Sendable, Equatable {
    let entries: [Entry]
    struct Entry: Sendable, Equatable {
        let tick: Int
        let bps: Double
    }

    init(entries: [(tick: Int, bps: Double)]) {
        var sorted = entries.map { Entry(tick: $0.tick, bps: $0.bps) }
        sorted.sort { $0.tick < $1.tick }
        if sorted.first?.tick != 0 {
            sorted.insert(Entry(tick: 0, bps: 2.0), at: 0)
        }
        self.entries = sorted
    }

    func bps(at tick: Int) -> Double {
        var lo = 0
        var hi = entries.count - 1
        var pick = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if entries[mid].tick <= tick {
                pick = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return entries[pick].bps
    }

    /// Build a tempo timeline from staff 0 / voice 0 of any staff.
    /// Caller passes the staff that owns the .tempo elements (typically
    /// staff 0). Mirrors the existing convention: `.tempo` events are
    /// sourced from voice 0.
    static func build(from staff: Staff, division: Int) -> TempoTimeline {
        var entries: [(tick: Int, bps: Double)] = [(0, 2.0)]
        var measureBase = 0
        for measure in staff.measures {
            let mTicks = MidiRenderer.measureTicks(
                measure: measure, division: division
            )
            if let voice = measure.voices.first {
                var localTick = measureBase
                for element in voice.elements {
                    switch element {
                    case let .tempo(t):
                        entries.append((tick: localTick, bps: t.beatsPerSecond))
                    case let .chord(chord):
                        localTick += chord.duration.ticks(division: division)
                    case let .locationShift(delta):
                        localTick += delta.ticks(division: division)
                    default:
                        break
                    }
                }
            }
            measureBase += mTicks
        }
        return TempoTimeline(entries: entries)
    }
}

extension FermataRanges {
    /// Sweep-merge result. `openEvents` are inserted AFTER the voice
    /// walks (so they sort after same-tick `.tempo` events), and
    /// `closeEvents` are inserted BEFORE the voice walks (so they
    /// sort before same-tick `.tempo`). The renderer's stable sort
    /// realises the close → .tempo → open ordering.
    struct TempoEvents: Sendable, Equatable {
        var openEvents: [TimedMidiEvent]
        var closeEvents: [TimedMidiEvent]
    }

    /// Convert a list of FermataRanges into tempo bookend events using
    /// piecewise-max sweep over the original-tick timeline.
    static func tempoEvents(
        ranges: [FermataRange],
        timeline: TempoTimeline
    ) -> TempoEvents {
        guard !ranges.isEmpty else { return TempoEvents(openEvents: [], closeEvents: []) }
        // Active-multiset of stretches keyed by endTick — at each
        // boundary we drop any with endTick ≤ current, then admit any
        // ranges starting at exactly current.
        var sortedByStart = ranges.sorted { $0.startTick < $1.startTick }
        let boundaries = uniqueBoundaries(of: ranges)
        var active: [FermataRange] = []   // small N; linear ops are fine
        var prevEffective: Double = 1.0
        var open: [TimedMidiEvent] = []
        var close: [TimedMidiEvent] = []

        for tick in boundaries {
            // Drop ranges that have already ended.
            active.removeAll { $0.endTick <= tick }
            // Admit any ranges starting at exactly this tick.
            while let next = sortedByStart.first, next.startTick == tick {
                active.append(next)
                sortedByStart.removeFirst()
            }
            let effective = active.map(\.stretch).max() ?? 1.0
            guard effective != prevEffective else { continue }

            let baseBps = timeline.bps(at: tick)
            let bookendBps = baseBps / effective
            let micros = Int((1_000_000.0 / bookendBps).rounded())
            let event = TimedMidiEvent(
                tick: tick, event: .meta(.tempo(microsecondsPerQuarter: micros))
            )
            if effective > prevEffective {
                open.append(event)
            } else {
                close.append(event)
            }
            prevEffective = effective
        }

        return TempoEvents(openEvents: open, closeEvents: close)
    }

    private static func uniqueBoundaries(of ranges: [FermataRange]) -> [Int] {
        var set = Set<Int>()
        for r in ranges {
            set.insert(r.startTick)
            set.insert(r.endTick)
        }
        return set.sorted()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FermataRangesTests -q`
Expected: PASS — all timeline + sweep-merge tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/FermataRanges.swift Tests/SheetMusicTests/FermataRangesTests.swift
git commit -m "midi: sweep-merge FermataRanges into tempo bookend events"
```

---

## Task 6: Wire fermata bookends into `MidiRenderer.renderTrack`

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer.swift:68-107`
- Test: `Tests/SheetMusicTests/FermataMidiTests.swift` (create)

The strategy is to splice the close events before, and the open events after, the voice walks — the existing stable sort then enforces close → .tempo → open at the same tick.

- [ ] **Step 1: Write the failing end-to-end tests**

Create `Tests/SheetMusicTests/FermataMidiTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct FermataMidiTests {
    private func chord(_ pitch: Int, _ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: 14)]))
    }
    private func rest(_ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: []))
    }
    private func fermata(_ subtype: String = "fermataAbove",
                        stretch: Double? = nil) -> VoiceElement {
        .fermata(Fermata(subtype: subtype, timeStretch: stretch))
    }
    private func makeScore(voices: [[VoiceElement]]) -> Score {
        let measure = Measure(voices: voices.map { Voice(elements: $0) })
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "voice",
                articulations: [InstrumentArticulation()]
            ),
            staves: [staff]
        )
        return Score(division: 480, parts: [part])
    }
    private func tempoEvents(_ file: MidiFile) -> [(Int, Int)] {
        file.tracks[0].events.compactMap {
            if case let .meta(.tempo(micros)) = $0.event {
                return ($0.tick, micros)
            }
            return nil
        }
    }
    private func micros(_ bpm: Double) -> Int {
        Int((60_000_000.0 / bpm).rounded())
    }

    // 1. Single normal fermata on quarter at 120 BPM.
    @Test func singleNormalFermataOnQuarter() throws {
        // C4 quarter [0..480), fermata, D4 quarter [480..960).
        let score = makeScore(voices: [[
            chord(60),
            fermata("fermataAbove"),
            chord(62),
        ]])
        let file = try MidiRenderer.render(score: score)
        // Expected: tempo 120 at tick 0 (header), tempo 80 at tick 480
        // (open: 120/1.5), tempo 120 at tick 960 (close).
        let tempos = tempoEvents(file)
        #expect(tempos == [
            (0,   micros(120)),
            (480, micros(80)),
            (960, micros(120)),
        ])
    }

    // 2. Long fermata on rest (grand pause).
    @Test func longFermataOnRest() throws {
        let score = makeScore(voices: [[
            chord(60),                              // 0..480 normal
            fermata("fermataLongAbove"),
            rest(.quarter),                         // 480..960 stretched
            chord(62),                              // 960..1440 normal
        ]])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        // 120 / 2.0 = 60 BPM during the rest range.
        #expect(tempos == [
            (0,   micros(120)),
            (480, micros(60)),
            (960, micros(120)),
        ])
    }

    // 3. Explicit timeStretch override.
    @Test func explicitTimeStretchOverride() throws {
        let score = makeScore(voices: [[
            fermata("fermataAbove", stretch: 2.5),
            chord(60),
        ]])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        // 120 / 2.5 = 48 BPM.
        #expect(tempos == [
            (0,   micros(48)),     // open at tick 0
            (480, micros(120)),    // close at tick 480
        ])
    }

    // 4. Fermata after chord in MSCX order (backward fallback).
    @Test func fermataAfterChordAnchorsBackwards() throws {
        let score = makeScore(voices: [[
            chord(60),                              // 0..480
            fermata("fermataAbove"),                // anchors back to C4
        ]])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        #expect(tempos == [
            (0,   micros(80)),     // open at tick 0 (stretch 1.5 of 120)
            (480, micros(120)),    // close at tick 480
        ])
    }

    // 5. Same-range fermata in two voices → single bookend pair (max stretch).
    @Test func sameRangeAcrossVoicesDeduped() throws {
        let score = makeScore(voices: [
            [fermata("fermataAbove"),     chord(60)],   // stretch 1.5, [0,480)
            [fermata("fermataLongAbove"), chord(60)],   // stretch 2.0, [0,480)
        ])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        // Max(1.5, 2.0) = 2.0 → 60 BPM.
        #expect(tempos == [
            (0,   micros(60)),
            (480, micros(120)),
        ])
    }

    // 6. Partial overlap → sweep-merge produces correct staircase.
    @Test func partialOverlapTwoVoicesStaircase() throws {
        // Voice 1: dotted-quarter (720 ticks @ div=480) stretch 2.0
        // Voice 2: quarter starting at 240 ticks (via leading 8th rest)
        //          stretch 1.5 over [240, 720)
        let score = makeScore(voices: [
            [fermata("fermataLongAbove"),                       // stretch 2.0 → 480
             chord(60, .dottedQuarter)],                        // 0..720
            [rest(.eighth),                                     // 0..240
             fermata("fermataAbove"),                           // stretch 1.5
             chord(62, .quarter)],                              // 240..720
        ])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        // [0, 720) max=2.0; [720, ∞) restore. The voice-2 fermata is
        // covered entirely by the voice-1 fermata so it disappears
        // (max merge eliminates the redundant 240 boundary).
        #expect(tempos == [
            (0,   micros(60)),     // 120/2.0
            (720, micros(120)),
        ])
    }

    // 7. Boundary co-location: .tempo lands at fermata's endTick.
    @Test func endBoundaryTempoChangeWins() throws {
        // Fermata covers [0, 480). At tick 480 a .tempo(3.0 bps = 180 BPM)
        // lands. Close emits 180 BPM; .tempo also emits 180 BPM. Stable
        // sort: close first → .tempo second → no observable difference
        // (both write 180), but the post-fermata tempo is 180.
        let score = makeScore(voices: [[
            fermata("fermataAbove"),                            // stretch 1.5
            chord(60),                                          // 0..480
            .tempo(Tempo(beatsPerSecond: 3.0)),                 // at tick 480
            chord(62),                                          // 480..960
        ]])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        // Open at 0: 120/1.5 = 80; close at 480: 180 (timeline lookup
        // post-tempo); .tempo also writes 180 at 480. We expect both to
        // appear (last-write-wins is the renderer's convention).
        #expect(tempos == [
            (0,   micros(80)),
            (480, micros(180)),    // close (timeline post-.tempo)
            (480, micros(180)),    // .tempo from voice walk
        ])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FermataMidiTests -q`
Expected: FAIL — fermatas still no-op in MIDI render. The renderer needs to splice the bookends.

- [ ] **Step 3: Splice bookends in `renderTrack`**

In `Sources/SheetMusicMIDI/Render/MidiRenderer.swift`, replace the body of `renderTrack` (lines 68-107) so it builds and inserts fermata bookends. Locate the function and update its body to:

```swift
        var events: [TimedMidiEvent] = headerEvents(
            staff: staff,
            part: part,
            channels: channels,
            port: port,
            isFirstTrack: isFirstTrack,
            isTopOfPart: isTopOfPart
        )

        // Per-staff fermata ranges + tempo bookends. Built BEFORE
        // voice walks so close events can be spliced ahead of any
        // same-tick `.tempo` from those walks.
        let fermataRanges = FermataRanges.collect(from: staff, division: division)
        let timeline = TempoTimeline.build(from: staff, division: division)
        let bookends = FermataRanges.tempoEvents(
            ranges: fermataRanges, timeline: timeline
        )

        // 1) Close events first — at any boundary tick they sort
        //    BEFORE same-tick .tempo / open events thanks to the
        //    stable insertion-order sort below.
        events.append(contentsOf: bookends.closeEvents)

        // 2) Voice events (which include any explicit .tempo elements).
        var voiceEventBuckets: [[TimedMidiEvent]] = []
        let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
        for voiceIndex in 0 ..< voiceCount {
            let (voiceEvents, _) = renderVoice(
                voiceIndex: voiceIndex,
                staff: staff,
                part: part,
                channel: primaryChannel,
                division: division,
                swingMap: swingMap
            )
            voiceEventBuckets.append(voiceEvents)
        }
        let merged = resolveUnisonOverlap(voiceEventBuckets.flatMap { $0 })
        events.append(contentsOf: merged)

        // 3) Open events last — at any boundary tick they sort AFTER
        //    same-tick .tempo so the held region uses the stretched
        //    post-.tempo base value.
        events.append(contentsOf: bookends.openEvents)

        let lastEventTick = events.map(\.tick).max() ?? 0
        events.append(TimedMidiEvent(tick: lastEventTick + 1, event: .endOfTrack))

        let sorted = events.enumerated()
            .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map(\.element)

        return MidiTrack(events: sorted)
```

- [ ] **Step 4: Replace the `.fermata` no-op site with a comment**

In `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` lines 268-273, the `.fermata` switch case currently no-ops with a long comment about MuseScore. Update it to reflect the new behaviour:

```swift
        case .fermata:
            // Held-duration is realised by per-staff tempo bookends
            // emitted in `MidiRenderer.renderTrack` from
            // `FermataRanges`. The voice walk does not need to
            // touch tempo or tick state here.
            break
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter FermataMidiTests -q`
Expected: PASS — all seven end-to-end fermata tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer.swift Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift Tests/SheetMusicTests/FermataMidiTests.swift
git commit -m "midi: emit fermata tempo bookends in renderTrack"
```

---

## Task 7: Full regression

**Files:** none modified.

- [ ] **Step 1: Run the full test suite**

Run: `swift test -q`
Expected: All tests green, including the 12 `MidiExportTests` MuseScore-equivalence cases. None of those fixtures contain fermatas, so the per-staff `FermataRanges.collect` returns `[]`, `tempoEvents` returns empty arrays, and behaviour is unchanged for them.

- [ ] **Step 2: Run SwiftLint**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors. If any new file trips the 300-line cap, split it (e.g. lift `TempoTimeline` into its own file).

- [ ] **Step 3: If everything green, no further commit needed.**

If lint changes were required to keep files under 300 lines, commit them separately:

```bash
git add Sources/SheetMusicMIDI/Render/
git commit -m "midi: extract TempoTimeline into its own file"
```

---

## Self-review notes (already addressed above)

- **Spec coverage:** every section of `2026-05-10-fermata-midi-design.md` maps to a task — model (Task 1), MSCX I/O (Tasks 2-3), FermataRanges + dedupe (Task 4), TempoTimeline + sweep-merge (Task 5), renderer integration with ordering rule (Task 6), regression (Task 7).
- **Anchor-rule coverage:** Task 4 tests forward, backward, drop-silently, and rest cases.
- **Sweep-merge coverage:** Task 5 tests single, redundant-overlap (drops boundary), and staircase. Task 6 covers the staircase end-to-end through `renderTrack`.
- **Boundary co-location:** Task 5 tests it via timeline lookup; Task 6 confirms the renderer ordering produces the right MIDI output.
