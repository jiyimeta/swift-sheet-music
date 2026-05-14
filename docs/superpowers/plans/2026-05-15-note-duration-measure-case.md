# NoteDuration `.measure` Case — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `NoteDuration.measure` so a full-measure rest is modelled as a context-free marker, fix the 6/4 dotted-rest rendering bug, align multi-measure-rest collapse with MuseScore, and migrate parsers / encoders / tick-walkers to resolve `.measure` against each measure's effective duration.

**Architecture:** `.measure` is a context-free marker; `asFraction` / `ticks(division:)` / `dotted(_:)` trap on it. Callers that may see `.measure` first call `duration.resolved(in: measureFrac)`, where `measureFrac = measure.actualLength ?? prevailingTimeSignatureFraction`. A new `Score.effectiveMeasureDurations(...)` helper builds the per-measure array; encoders / renderers index it. Spec source: `docs/superpowers/specs/2026-05-15-note-duration-measure-case-design.md`.

**Tech Stack:** Swift 5.9+, Swift Testing (`@Test`/`#expect`), SPM. Core / Layout / MSCX / MusicXML / MIDI / Audio / UI sub-libraries.

---

## File Structure

**Created:**
- `Sources/SheetMusicCore/Score/NoteDuration+Resolved.swift` — `resolved(in:)` helper.
- `Sources/SheetMusicCore/Score/Score+EffectiveMeasureDurations.swift` — per-measure effective-duration array.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration+InMeasure.swift` — `appendDurationXML(to:in:)` overload that knows how to spell `.measure`.
- `Tests/SheetMusicTests/MeterChangePreservesMeasureRestTests.swift` — meter-swap regression.
- `Tests/SheetMusicTests/EffectiveMeasureDurationsTests.swift` — Score helper tests.

**Modified (intent only — exact diffs in tasks):**
- `Sources/SheetMusicCore/Score/NoteDuration.swift` — add `case measure`; trap on context-free APIs.
- `Sources/SheetMusicCore/Score/VoiceElement.swift` — add `tickCount(division:in:)` overload.
- `Sources/SheetMusicLayout/Layout/DurationInterpretation.swift` — short-circuit `.measure` → `(.whole, 0)`.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift` — handle `.measure` in `durationWidth`; resolve in `tickAt` walks.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` — resolve `.measure` in per-measure tick walks.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Beaming.swift` — same.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Lyrics.swift` — same.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift` — same.
- `Sources/SheetMusicLayout/Layout/MultiMeasureRestPlanner.swift` — tighten predicate to require `.measure`.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Rest.swift` — emit `.measure` for `<durationType>measure</durationType>`.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+MeasureRepeat.swift` — emit `.measure` for measure-typed measure-repeats.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration.swift` — add `.measure` to switches.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+MeasureRepeat.swift` — add `.measure` arm to switch.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift` — `encodeAsRest` overload taking measure duration.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift` — thread `effectiveDuration: Fraction` parameter; resolve `.measure` before tracking voice totals.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice+Ties.swift` — resolve before tie computations.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift` — accept and forward `effectiveDuration` parameter.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift` — pass `effectiveMeasureDurations` array down.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift` (or wherever `Staff.encodeTopLevel` is called) — build the effective-duration array via `Score.effectiveMeasureDurations()`.
- `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift` — detect `<rest measure="yes"/>` and emit `.measure`.
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` — resolve `.measure` at top of per-measure loop.
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Repeats.swift` — resolve in repeat-block tick accumulation.
- `Sources/SheetMusicMIDI/Render/HairpinRamps.swift`, `OttavaRanges.swift`, `FermataRanges.swift`, `MidiRenderer+Swing.swift` — resolve in per-measure tick walks.
- `Sources/SheetMusicAudio/PlaybackTimeline.swift` — resolve in per-measure tick walks.
- `Sources/SheetMusicAudio/MetronomeBeat.swift` — resolve.
- `Sources/SheetMusicUI/PlaybackCursorView.swift` — resolve in per-measure tick walks.
- `Sources/SheetMusicCore/Score/Score+NoteRange.swift` — resolve.
- `Sources/SheetMusicPDF/Import/PDFImporter+Rhythm.swift` — add `.measure` arm to `halve`.

**Tests modified:**
- `Tests/SheetMusicTests/MS2CompatibilityTests.swift` — assert `.measure` instead of `Fraction(5, 4)`.
- `Tests/SheetMusicTests/MultiMeasureRestPlannerTests.swift` — author rest measures with `.measure` instead of `.whole`; add split-rest-not-collapsed regression.
- `Tests/SheetMusicTests/DurationInterpretationTests.swift` — add `.measure` → `(.whole, 0)` cases.

---

## Task 1: Foundation — add `.measure` case, traps, helpers, and update every in-package exhaustive switch in one commit

**Why one commit:** `NoteDuration` is a `public` enum used in exhaustive switches across the package. Adding `case measure` without updating every switch breaks the build. Bundling them keeps the package compiling at the commit boundary, per the CLAUDE.md / `feedback_swift_enum_case_addition_scope` guidance.

**Files:**
- Modify: `Sources/SheetMusicCore/Score/NoteDuration.swift`
- Create: `Sources/SheetMusicCore/Score/NoteDuration+Resolved.swift`
- Create: `Sources/SheetMusicCore/Score/Score+EffectiveMeasureDurations.swift`
- Modify: `Sources/SheetMusicCore/Score/VoiceElement.swift`
- Modify: `Sources/SheetMusicLayout/Layout/DurationInterpretation.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift` (line ~518)
- Modify: `Sources/SheetMusicPDF/Import/PDFImporter+Rhythm.swift` (line ~219)
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration.swift` (line ~21, ~67)
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+MeasureRepeat.swift` (line ~31)
- Test: `Tests/SheetMusicTests/EffectiveMeasureDurationsTests.swift` (new file)
- Test: existing `DurationInterpretationTests.swift` (add new `.measure` cases — see step 11)

- [ ] **Step 1: Write the new failing tests for `Score.effectiveMeasureDurations()`**

Create `Tests/SheetMusicTests/EffectiveMeasureDurationsTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

struct EffectiveMeasureDurationsTests {
    private static func makeScore(
        timeSignaturesByMeasure: [(Int, Int)?],
        actualLengths: [Fraction?] = [],
    ) -> Score {
        let measures = timeSignaturesByMeasure.enumerated().map { i, ts -> Measure in
            var voices: [VoiceElement] = []
            if let (n, d) = ts {
                voices.append(.timeSignature(TimeSignature(numerator: n, denominator: d)))
            }
            voices.append(.rest(duration: .whole))
            var m = Measure(voices: [Voice(elements: voices)])
            if i < actualLengths.count, let len = actualLengths[i] {
                m.actualLength = len
            }
            return m
        }
        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: measures)],
            )],
            systemMeasures: Array(repeating: SystemMeasure(), count: measures.count),
        )
    }

    @Test func defaultsToFourFourWhenNoTimeSignature() {
        let s = Self.makeScore(timeSignaturesByMeasure: [nil, nil])
        let durations = s.effectiveMeasureDurations()
        #expect(durations == [
            Fraction(numerator: 4, denominator: 4),
            Fraction(numerator: 4, denominator: 4),
        ])
    }

    @Test func picksUpInitialTimeSignature() {
        let s = Self.makeScore(timeSignaturesByMeasure: [(6, 4), nil, nil])
        let durations = s.effectiveMeasureDurations()
        #expect(durations == Array(repeating: Fraction(numerator: 6, denominator: 4), count: 3))
    }

    @Test func tracksMidScoreTimeSignatureChange() {
        let s = Self.makeScore(timeSignaturesByMeasure: [(4, 4), nil, (3, 4), nil])
        let durations = s.effectiveMeasureDurations()
        #expect(durations == [
            Fraction(numerator: 4, denominator: 4),
            Fraction(numerator: 4, denominator: 4),
            Fraction(numerator: 3, denominator: 4),
            Fraction(numerator: 3, denominator: 4),
        ])
    }

    @Test func actualLengthOverridesPrevailingTimeSignature() {
        let s = Self.makeScore(
            timeSignaturesByMeasure: [(4, 4), nil, nil],
            actualLengths: [nil, Fraction(numerator: 2, denominator: 4), nil],
        )
        let durations = s.effectiveMeasureDurations()
        #expect(durations == [
            Fraction(numerator: 4, denominator: 4),
            Fraction(numerator: 2, denominator: 4),
            Fraction(numerator: 4, denominator: 4),
        ])
    }
}
```

- [ ] **Step 2: Run the new tests — expect compile failure**

Run: `swift test --filter EffectiveMeasureDurationsTests`
Expected: build error (`effectiveMeasureDurations` undefined; `.measure` may also be referenced by Step 11 additions — that's fine, all of Task 1's edits land together).

- [ ] **Step 3: Add `case measure` and traps in `NoteDuration.swift`**

Replace `Sources/SheetMusicCore/Score/NoteDuration.swift` so the enum exposes the new case and the context-free methods loudly reject it:

```swift
import Foundation

/// Standard note duration. C++: `mu::engraving::TDuration` (subset).
/// `.fraction` covers irregular durations encoded as raw fractions
/// (e.g. tuplet-scaled members written `<duration>1/12</duration>`).
/// `.measure` is a marker for "this rest fills the containing
/// measure" — it carries no intrinsic duration; consumers must call
/// `resolved(in:)` against the measure's effective duration before
/// asking for ticks or a Fraction. Mirrors MuseScore's
/// `DurationType::V_MEASURE` and MusicXML's `<rest measure="yes"/>`.
public enum NoteDuration: Sendable, Equatable {
    case whole
    case half
    case quarter
    case eighth
    case sixteenth
    case thirtySecond
    case sixtyFourth
    case oneTwentyEighth
    case twoFiftySixth
    case fraction(Fraction)
    case measure

    /// Number of MIDI ticks at a given PPQ division. quarter = 1 * division.
    /// Traps on `.measure` — call `resolved(in:)` first.
    public func ticks(division: Int) -> Int {
        switch self {
        case .whole: return 4 * division
        case .half: return 2 * division
        case .quarter: return division
        case .eighth: return division / 2
        case .sixteenth: return division / 4
        case .thirtySecond: return division / 8
        case .sixtyFourth: return division / 16
        case .oneTwentyEighth: return division / 32
        case .twoFiftySixth: return division / 64
        case let .fraction(f): return f.ticks(division: division)
        case .measure:
            preconditionFailure(
                ".measure has no fixed tick count; "
                    + "resolve via resolved(in:) first",
            )
        }
    }

    /// Decode from MuseScore mscx `<durationType>` text values.
    /// Returns nil for "measure" — callers parse the parent element
    /// to decide between `.measure` and a typed rest.
    public init?(mscxName: String) {
        switch mscxName {
        case "whole": self = .whole
        case "half": self = .half
        case "quarter": self = .quarter
        case "eighth": self = .eighth
        case "16th": self = .sixteenth
        case "32nd": self = .thirtySecond
        case "64th": self = .sixtyFourth
        case "128th": self = .oneTwentyEighth
        case "256th": self = .twoFiftySixth
        default: return nil
        }
    }

    /// This duration expressed as a fraction of a whole note. Traps
    /// on `.measure` — call `resolved(in:)` first.
    public var asFraction: Fraction {
        switch self {
        case .whole: return Fraction(numerator: 1, denominator: 1)
        case .half: return Fraction(numerator: 1, denominator: 2)
        case .quarter: return Fraction(numerator: 1, denominator: 4)
        case .eighth: return Fraction(numerator: 1, denominator: 8)
        case .sixteenth: return Fraction(numerator: 1, denominator: 16)
        case .thirtySecond: return Fraction(numerator: 1, denominator: 32)
        case .sixtyFourth: return Fraction(numerator: 1, denominator: 64)
        case .oneTwentyEighth: return Fraction(numerator: 1, denominator: 128)
        case .twoFiftySixth: return Fraction(numerator: 1, denominator: 256)
        case let .fraction(f): return f
        case .measure:
            preconditionFailure(
                ".measure has no fixed duration; "
                    + "resolve via resolved(in:) first",
            )
        }
    }

    /// Apply augmentation dots: each dot extends the duration by half
    /// of the prior length (1 dot = 1.5x, 2 dots = 1.75x, …). Returns
    /// a `.fraction` with the result. Traps on `.measure` — augmenting
    /// a measure-rest marker has no musical meaning.
    public func dotted(_ dots: Int) -> NoteDuration {
        precondition(dots >= 0, "dots must be non-negative")
        if dots == 0 { return self }
        if case .measure = self {
            preconditionFailure(
                ".measure cannot be augmented with dots",
            )
        }
        let base = asFraction
        let factorNumerator = (1 << (dots + 1)) - 1
        let factorDenominator = 1 << dots
        let n = base.numerator * factorNumerator
        let d = base.denominator * factorDenominator
        return .fraction(Fraction(numerator: n, denominator: d))
    }
}
```

- [ ] **Step 4: Add `resolved(in:)` helper**

Create `Sources/SheetMusicCore/Score/NoteDuration+Resolved.swift`:

```swift
import Foundation

extension NoteDuration {
    /// Replace `.measure` with `.fraction(measureDuration)`. All other
    /// cases pass through unchanged. Use this at the boundary of a
    /// per-measure loop so context-free helpers (`asFraction`,
    /// `ticks(division:)`) never trap on `.measure`.
    public func resolved(in measureDuration: Fraction) -> NoteDuration {
        switch self {
        case .measure: return .fraction(measureDuration)
        default: return self
        }
    }
}
```

- [ ] **Step 5: Add `Score.effectiveMeasureDurations(partIndex:staffIndex:)`**

Create `Sources/SheetMusicCore/Score/Score+EffectiveMeasureDurations.swift`:

```swift
import Foundation

extension Score {
    /// Effective duration of each measure across the score, indexed
    /// by measure number. Equals the measure's `actualLength` when
    /// set, otherwise the prevailing `TimeSignature` (numerator /
    /// denominator) carried forward from earlier voice elements.
    /// Defaults to 4/4 when no time signature has appeared yet.
    ///
    /// TimeSignature changes are score-wide in this model, so reading
    /// from a single (part, staff) is sufficient. The first part /
    /// first staff is the default.
    ///
    /// Used by encoders / renderers / tick walkers that need to
    /// resolve `.measure` durations against the containing bar.
    public func effectiveMeasureDurations(
        partIndex: Int = 0,
        staffIndex: Int = 0,
    ) -> [Fraction] {
        guard partIndex < parts.count,
              staffIndex < parts[partIndex].staves.count
        else { return [] }
        let measures = parts[partIndex].staves[staffIndex].measures
        var prevailing = Fraction(numerator: 4, denominator: 4)
        var result: [Fraction] = []
        result.reserveCapacity(measures.count)
        for measure in measures {
            for el in measure.voices.flatMap(\.elements) {
                if case let .timeSignature(ts) = el {
                    prevailing = Fraction(
                        numerator: ts.numerator,
                        denominator: ts.denominator,
                    )
                    // The first time signature in a measure governs
                    // that measure; later ones (rare) still carry
                    // forward to subsequent measures.
                    break
                }
            }
            result.append(measure.actualLength ?? prevailing)
        }
        return result
    }
}
```

- [ ] **Step 6: Add `VoiceElement.tickCount(division:in:)` overload**

Append to `Sources/SheetMusicCore/Score/VoiceElement.swift` (the existing `tickCount(division:)` stays — it traps via `NoteDuration.ticks(division:)` if it ever sees `.measure`, which is what we want for misuse detection):

```swift
extension VoiceElement {
    /// Like `tickCount(division:)`, but resolves a `.measure` rest
    /// against the supplied measure duration first. Use this when
    /// walking voice elements per-measure where rest-shaped chords
    /// may carry `.measure`.
    public func tickCount(
        division: Int, in measureDuration: Fraction,
    ) -> Int? {
        if case let .chord(c) = self {
            return c.duration
                .resolved(in: measureDuration)
                .ticks(division: division)
        }
        return nil
    }
}
```

- [ ] **Step 7: Add `.measure` short-circuit in `DurationInterpretation.split`**

In `Sources/SheetMusicLayout/Layout/DurationInterpretation.swift`, change the outer switch to include `.measure`. Replace the `switch dur {` block (lines 25–78) with:

```swift
        switch dur {
        case .whole, .half, .quarter, .eighth, .sixteenth,
             .thirtySecond, .sixtyFourth,
             .oneTwentyEighth, .twoFiftySixth:
            return (dur, 0)
        case .measure:
            // A `.measure` rest renders as a single whole-rest glyph
            // hanging from staff line 4, with no augmentation dot,
            // regardless of meter (SMuFL `restWhole` U+E4E3 — the
            // universal full-measure-rest glyph). Short-circuiting
            // here also fixes the legacy 6/4 / 3/4 / 6/8 / 12/8
            // dotted-rest miscategorisation that came from passing
            // these through the dotted-pattern heuristic below.
            return (.whole, 0)
        case let .fraction(f):
            // ... existing block unchanged ...
```

(Leave the rest of the function body — the `.fraction(f)` case and `baseAndDots` / `isPowerOfTwo` / `gcd` helpers — untouched.)

- [ ] **Step 8: Add `.measure` arm to `LayoutEngine+Spacing.swift` `durationWidth`**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift` around line 508, the switch on `dur`. Add a `.measure` case that delegates to whole-rest spacing — `.measure` rests render with the whole-rest glyph and need its allotted width. Insert before the `case let .fraction(f):` arm:

```swift
        case .measure:
            // Renders as a whole-rest glyph; allocate whole-rest width.
            quarters = 4
```

- [ ] **Step 9: Add `.measure` arm to `PDFImporter+Rhythm.swift` `halve`**

In `Sources/SheetMusicPDF/Import/PDFImporter+Rhythm.swift` around line 209, the `halve` switch. The PDF importer never produces `.measure` (per spec §"PDF importer"), but the switch must remain exhaustive. Add:

```swift
        case .measure: .measure
```

(A `.measure` halved is still `.measure` — semantically a no-op for an importer that won't see it. This keeps the type system happy without inventing behaviour.)

- [ ] **Step 10: Add `.measure` arms to MSCX encoder switches**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration.swift`:

- The `mscxName` switch (around line 10) needs `.measure: nil` added to the bottom:

```swift
        case .fraction: nil
        case .measure: nil
```

(Returning nil tells the caller this duration cannot be expressed as a named base + dots, so it must use the `<durationType>measure</durationType>` form.)

- The `appendDurationXML(to:)` function (around line 59) currently only handles `.fraction(...)` after `decomposed()` returns nil. We do not extend it to handle `.measure` here — the encoder must call the new `appendDurationXML(to:in:)` overload (added in Task 5) when it might see `.measure`. To make that boundary loud, add an explicit guard:

```swift
    func appendDurationXML(to children: inout [XMLTreeNode]) {
        if case .measure = self {
            preconditionFailure(
                "appendDurationXML: .measure must be written via "
                    + "the appendDurationXML(to:in:) overload that "
                    + "carries the effective measure duration",
            )
        }
        if let parts = decomposed() {
            // ... existing body unchanged ...
```

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+MeasureRepeat.swift` (around line 31), the `if case let .fraction(f) = duration` branch needs to also fire for `.measure`. The simplest fix here is an early branch:

```swift
        switch duration {
        case .measure:
            preconditionFailure(
                "MeasureRepeat.encode: `.measure` duration must be "
                    + "resolved before encode() is called",
            )
        case let .fraction(f):
            children.append(XMLTreeNode(name: "durationType", text: "measure"))
            children.append(XMLTreeNode(
                name: "duration",
                text: "\(f.numerator)/\(f.denominator)",
            ))
        default:
            duration.appendDurationXML(to: &children)
        }
```

(Resolution will be threaded through in Task 5.)

- [ ] **Step 11: Add `.measure` cases to `DurationInterpretationTests`**

Append to `Tests/SheetMusicTests/DurationInterpretationTests.swift`:

```swift
    // MARK: - .measure short-circuit (6/4 dotted-rest bug fix)

    @available(macOS 15.0, iOS 16.0, *)
    @Test func measureRendersAsPlainWholeRest() {
        // Spec Goal #3: regardless of meter, a `.measure` rest
        // renders with the whole-rest glyph and no augmentation dot.
        let split = DurationInterpretation.split(.measure)
        #expect(split.base == .whole)
        #expect(split.dots == 0)
    }
```

(The `multiMeasureRestFractionsHaveNoDots` test already covers the
`.fraction(...)`-based spelling via the power-of-two-denominator
fallback. The `.measure` case is now the canonical spelling and gets
its own assertion above.)

- [ ] **Step 12: Build and run the full test suite**

Run: `swift build`
Expected: success — every previously-exhaustive switch on `NoteDuration` now also handles `.measure`.

Run: `swift test`
Expected: success. New `EffectiveMeasureDurationsTests` and the new `measureRendersAsPlainWholeRest` case pass; no existing tests fail (no caller produces `.measure` yet, so the traps are not exercised).

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors.

- [ ] **Step 13: Commit**

```bash
git add Sources/SheetMusicCore/Score/NoteDuration.swift \
        Sources/SheetMusicCore/Score/NoteDuration+Resolved.swift \
        Sources/SheetMusicCore/Score/Score+EffectiveMeasureDurations.swift \
        Sources/SheetMusicCore/Score/VoiceElement.swift \
        Sources/SheetMusicLayout/Layout/DurationInterpretation.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift \
        Sources/SheetMusicPDF/Import/PDFImporter+Rhythm.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+MeasureRepeat.swift \
        Tests/SheetMusicTests/EffectiveMeasureDurationsTests.swift \
        Tests/SheetMusicTests/DurationInterpretationTests.swift
git commit -m "core: add NoteDuration.measure marker case and helpers"
```

---

## Task 2: Migrate per-measure tick walkers to use `resolved(in:)` (defensive — no `.measure` flowing through yet)

**Why now:** The decoder change in Task 5 will start emitting `.measure`. Every per-measure tick walker that may consume those rests must already be safe by then. Each touched file is its own commit so review stays incremental — but they can all land before Task 5.

The general pattern (spec §"Per-call-site migration"):

```swift
let durations = score.effectiveMeasureDurations()
for (i, measure) in staff.measures.enumerated() {
    let measureFrac = durations[i]
    for el in measure.voices.flatMap(\.elements) {
        if case let .chord(c) = el {
            let t = c.duration
                .resolved(in: measureFrac)
                .ticks(division: division)
            // ...
        }
    }
}
```

Tuplet-internal scans, grace-chord paths, and `MeasurePosition.offset` arithmetic do NOT need resolution — they cannot see `.measure` (a measure-rest is never inside a tuplet and never a grace, and `MeasurePosition.offset` is a Fraction not a `NoteDuration`). Skip them.

### Task 2a: MIDI render path

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` (lines 213, 228)
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Repeats.swift` (line 109)
- Modify: `Sources/SheetMusicMIDI/Render/HairpinRamps.swift` (line 143)
- Modify: `Sources/SheetMusicMIDI/Render/OttavaRanges.swift` (line 87)
- Modify: `Sources/SheetMusicMIDI/Render/FermataRanges.swift` (lines 52, 65)
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Swing.swift` (lines 215, 232)

- [ ] **Step 1: Locate the per-measure entry point in `MidiRenderer+Voice.swift`**

Read `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` to identify where `voiceElements` for a single measure are iterated. The switch at lines ~184–230 is the per-element step. The enclosing call already knows `measureIndex` and the score; pull the effective-duration array once per render and index into it.

- [ ] **Step 2: Thread `measureDuration: Fraction` to `emitElement`**

At the per-measure caller of the element switch, compute `measureDuration` once (from a `Score.effectiveMeasureDurations()` array built at render-entry, cached for the duration of the render). Pass it as a parameter into the function holding the switch (`emitElement` or its caller).

Inside the switch, replace the two call sites that read `chord.duration.ticks(division:)`:

```swift
        case let .chord(chord) where chord.notes.isEmpty:
            // Rest: advance the tick cursor, emit no note events.
            localTick += chord.duration
                .resolved(in: measureDuration)
                .ticks(division: division)
        // ...
        case let .chord(chord):
            // ...
            let chordTicks = chord.duration
                .resolved(in: measureDuration)
                .ticks(division: division)
```

Plain note chords never carry `.measure`, but `resolved(in:)` is a no-op for non-`.measure` durations so the unconditional resolve is safe and uniform.

- [ ] **Step 3: Apply the same pattern to the other MIDI render files**

Each of `MidiRenderer+Repeats.swift`, `HairpinRamps.swift`, `OttavaRanges.swift`, `FermataRanges.swift`, `MidiRenderer+Swing.swift` has a per-measure (or per-staff-walk) loop summing `chord.duration.ticks(division:)`. For each:

1. At the top of the per-measure loop, compute `let measureFrac = effectiveDurations[measureIndex]`.
2. Wrap `chord.duration.ticks(division: division)` as `chord.duration.resolved(in: measureFrac).ticks(division: division)`.

The exact local context (parameter names, what's already in scope) varies — apply the spec's pattern as written.

- [ ] **Step 4: Build and test**

Run: `swift build && swift test`
Expected: success — no behaviour change because `.measure` is not yet produced by any decoder.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMIDI/Render
git commit -m "midi render: resolve .measure rests against effective measure duration"
```

### Task 2b: Audio playback / metronome

**Files:**
- Modify: `Sources/SheetMusicAudio/PlaybackTimeline.swift` (lines 211, 240, 279)
- Modify: `Sources/SheetMusicAudio/MetronomeBeat.swift` (line 63)

- [ ] **Step 1: Read `PlaybackTimeline.swift` around the per-measure walk**

Identify the enclosing measure-iteration scope. The three call sites at lines 211 / 240 / 279 are inside the same per-measure loop body. Compute `measureFrac` once at the top.

- [ ] **Step 2: Wrap each tick read with `resolved(in:)`**

Same pattern as 2a Step 3.

- [ ] **Step 3: Apply the same pattern to `MetronomeBeat.swift` line 63**

`measureLen += c.duration.ticks(division: division)` → resolve first.

- [ ] **Step 4: Build and test**

Run: `swift build && swift test`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudio/PlaybackTimeline.swift \
        Sources/SheetMusicAudio/MetronomeBeat.swift
git commit -m "audio: resolve .measure rests in playback timeline / metronome"
```

### Task 2c: Layout engine

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` (lines 201, 246, 294, 537)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Beaming.swift` (lines 56, 84, 89, 135)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Lyrics.swift` (lines 212, 228)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift` (line 327)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift` (lines 307, 320)

- [ ] **Step 1: Read each enclosing scope and identify the measureFrac source**

Each file has multiple call sites; some are inside per-measure loops (resolve as above), others are inside tuplet inner loops (skip — `.measure` cannot appear).

For sites inside a per-measure loop, build / pass `effectiveMeasureDurations` from the layout entry point.

For sites that walk a single measure's voice (e.g. `+Beaming.swift` lines 56–135 are per-measure beam scans), read the enclosing function's measure index and resolve.

- [ ] **Step 2: Apply the resolve wrap**

Same pattern as 2a.

- [ ] **Step 3: Build and test**

Run: `swift build && swift test`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicLayout/Layout
git commit -m "layout: resolve .measure rests in placement / beaming / lyrics / spacing walks"
```

### Task 2d: Core / UI tick walkers

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Score+NoteRange.swift` (lines 67, 78, 116, 140)
- Modify: `Sources/SheetMusicUI/PlaybackCursorView.swift` (lines 228, 244, 387)

- [ ] **Step 1: Apply resolve to `Score+NoteRange.swift`**

`Score` already has `effectiveMeasureDurations()`; call it once and index by measure.

- [ ] **Step 2: Apply resolve to `PlaybackCursorView.swift`**

The view already gets a `Score`; build the durations array per layout pass.

- [ ] **Step 3: Build and test**

Run: `swift build && swift test`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicCore/Score/Score+NoteRange.swift \
        Sources/SheetMusicUI/PlaybackCursorView.swift
git commit -m "core/ui: resolve .measure rests in note-range / playback-cursor walks"
```

### Task 2e: Editing helpers (defensive sweep)

**Files (audit only — most touch tuplet inner loops; resolve only where a `.measure` rest may flow in):**
- `Sources/SheetMusicCore/Editing/PasteVoiceElements.swift` (lines 100, 149) — pastes whole measures may carry `.measure`. Resolve.
- `Sources/SheetMusicCore/Editing/PasteVoiceElement.swift` (line 106) — same.
- `Sources/SheetMusicCore/Editing/SetRestDuration.swift` (lines 55–56) — receives a `rest` whose `duration` could be `.measure`. Resolve before computing `srcTicks`.
- `Sources/SheetMusicCore/Editing/SetChordDuration.swift` (lines 65–66) — chord, never `.measure`. Skip.
- `Sources/SheetMusicCore/Editing/DurationChangeAlgorithm.swift` (lines 103, 204, 236, 250) — operates on tuplet members and re-spelt durations, never `.measure`. Skip.
- `Sources/SheetMusicCore/Editing/RemoveTuplet.swift` (line 59) — tuplet member, never `.measure`. Skip.
- `Sources/SheetMusicCore/Editing/CreateTuplet.swift` (line 83) — tuplet target, never `.measure`. Skip.

- [ ] **Step 1: Resolve in the three identified places**

Each `Set*Duration` / `Paste*` site needs `measureDuration` from the editing context. The editing API takes a `Score` — call `effectiveMeasureDurations()` and look up by measure index.

If the context does not currently know the measure index, prefer adding a `measureDuration: Fraction` parameter to the helper (kept internal — no public API churn).

- [ ] **Step 2: Build and test**

Run: `swift build && swift test`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicCore/Editing
git commit -m "editing: resolve .measure rests in paste / set-rest-duration helpers"
```

---

## Task 3: MSCX encoder — accept `.measure` end-to-end via threaded effective-measure-duration

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift` (around line 66 — add overload)
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration+InMeasure.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift` (thread `effectiveDuration: Fraction` parameter)
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice+Ties.swift` (resolve before tie computations)
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift` (forward `effectiveDuration`)
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift` (pass per-measure effective durations)
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift` (build the effective-duration array via `Score.effectiveMeasureDurations()`)

- [ ] **Step 1: Add `appendDurationXML(to:in:)` overload**

Create `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration+InMeasure.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension NoteDuration {
    /// Append `<durationType>` (and `<duration>` when needed) for a
    /// duration that may be `.measure`. For `.measure`, emits
    /// `<durationType>measure</durationType><duration>N/D</duration>`
    /// where `N/D` is the supplied effective measure duration. For
    /// every other case, delegates to the context-free overload.
    func appendDurationXML(
        to children: inout [XMLTreeNode],
        in measureDuration: Fraction,
    ) {
        if case .measure = self {
            children.append(XMLTreeNode(
                name: "durationType", text: "measure",
            ))
            children.append(XMLTreeNode(
                name: "duration",
                text: "\(measureDuration.numerator)/\(measureDuration.denominator)",
            ))
            return
        }
        appendDurationXML(to: &children)
    }
}
```

- [ ] **Step 2: Add `Chord.encodeAsRest(options:in:)` overload**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`, add a new method on `Chord` directly below `encodeAsRest(options:)`:

```swift
    /// Encode as a `<Rest>` (notes-empty representation), resolving
    /// `.measure` against the supplied effective measure duration.
    func encodeAsRest(
        options: MSCXEncoderOptions = .init(),
        in measureDuration: Fraction,
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children, in: measureDuration)
        return XMLTreeNode(name: "Rest", children: children)
    }
```

The single-argument `encodeAsRest(options:)` stays — it traps via `appendDurationXML`'s precondition if a `.measure` rest reaches it (helpful misuse detection).

- [ ] **Step 3: Thread `effectiveDuration` through `Voice.encode`**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift`:

- Add `effectiveDuration: Fraction` to the public `encode(carryIn:isStaffHead:options:staffGroup:voiceIndex:systemElements:)` signature (default `Fraction(numerator: 4, denominator: 4)` for source-compatibility — callers that do not yet supply it get the previous behaviour for non-`.measure` content).
- Replace the body's `let voiceBarLength = computedBarLength()` with `let voiceBarLength = effectiveDuration` for the `.measure`-bearing voices, but keep the old path when no `.measure` is present:

```swift
let voiceBarLength = elements.contains(where: { $0.isMeasureRest })
    ? effectiveDuration
    : computedBarLength()
```

Add a small helper on `VoiceElement` (in the same file or `VoiceElement.swift`):

```swift
extension VoiceElement {
    var isMeasureRest: Bool {
        if case let .chord(c) = self,
           c.notes.isEmpty,
           case .measure = c.duration { return true }
        return false
    }
}
```

- Inside the per-element loop, replace the two `chord.duration.asFraction` reads at lines 217 and 222 with resolves:

```swift
            let chordFrac = chord.duration
                .resolved(in: effectiveDuration)
                .asFraction
            state.previousChordDuration = chordFrac
            state.seenChordInVoice = true
            state.voiceTotal = state.voiceTotal + chordFrac
```

- Also replace the line-375 sum in `computedBarLength()` so it does not trap if it is ever called with a `.measure` voice (defensive — the conditional above is the primary guard, but keep this safe):

```swift
    private func computedBarLength() -> Fraction {
        elements.reduce(Fraction(numerator: 0, denominator: 1)) { acc, element in
            if case let .chord(chord) = element {
                if case .measure = chord.duration { return acc }
                return acc + chord.duration.asFraction
            }
            return acc
        }
    }
```

(`.measure` chords contribute zero in this fallback; the caller substitutes `effectiveDuration` instead.)

- In `encodeChord(...)`, when the chord is a rest, route through the new overload:

```swift
        return unscaledChord.notes.isEmpty
            ? unscaledChord.encodeAsRest(options: options, in: effectiveDuration)
            : unscaledChord.encodeAsChord(...)
```

The `unscaledDuration` helper at line 400 calls `.asFraction`; if `chord.duration == .measure` that traps. A `.measure` rest is never inside a tuplet, so guard:

```swift
    private func unscaledDuration(
        _ duration: NoteDuration, in tuplets: [Tuplet],
    ) throws -> NoteDuration {
        guard !tuplets.isEmpty else { return duration }
        if case .measure = duration { return duration }   // never tuplet-scaled
        // ... existing body unchanged ...
    }
```

- Update the line-404 `duration.asFraction` similarly — the early-return above means we no longer reach asFraction on `.measure`, so existing line-404 stays.

- [ ] **Step 4: Resolve in `MSCXEncoder+Voice+Ties.swift`**

Line 20: `let dur = chord.duration.asFraction` — wrap with `chord.duration.resolved(in: voiceBarLength).asFraction`. (A `.measure` rest has no ties, so this resolution is technically unreachable for rests; doing it anyway keeps the code uniform and trap-safe.)

- [ ] **Step 5: Forward `effectiveDuration` from `Measure.encode`**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift`, add an `effectiveDuration: Fraction` parameter to both `encode(...)` overloads (default `Fraction(numerator: 4, denominator: 4)` for source-compat). Forward it to each `voice.encode(...)` call inside the measure-encoding loop.

- [ ] **Step 6: Pass per-measure durations from `Staff.encodeTopLevel`**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift`, add an `effectiveMeasureDurations: [Fraction] = []` parameter to `encodeTopLevel(...)`. In the per-measure loop:

```swift
        for (measureIndex, measure) in measures.enumerated() {
            let measureFrac = measureIndex < effectiveMeasureDurations.count
                ? effectiveMeasureDurations[measureIndex]
                : Fraction(numerator: 4, denominator: 4)
            // ...
            let result = try measure.encode(
                carryInVoiceTieCarries: carry,
                isFirstMeasureOfStaff: measureIndex == 0,
                options: options,
                staffGroup: group,
                voice0SystemElements: injection,
                effectiveDuration: measureFrac,
            )
            // ...
        }
```

- [ ] **Step 7: Build the array at the score-encoder entry point**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`, find every call to `Staff.encodeTopLevel(...)`. Before the per-staff loop, build:

```swift
let effectiveDurations = score.effectiveMeasureDurations()
```

and pass it via the new parameter.

- [ ] **Step 8: Build and test**

Run: `swift build && swift test`
Expected: success — no behaviour change visible because no decoder yet emits `.measure`. The `MSCXEncoderTests` and `MidiExportTests` semantic-equivalence suite both stay green.

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors.

- [ ] **Step 9: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders
git commit -m "mscx encode: thread effective measure duration; encode .measure rests"
```

---

## Task 4: Tighten `MultiMeasureRestPlanner.isCollapsible` and migrate planner tests

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/MultiMeasureRestPlanner.swift` (lines 152–153)
- Modify: `Tests/SheetMusicTests/MultiMeasureRestPlannerTests.swift`

**Why same commit:** The existing `MultiMeasureRestPlannerTests` builds rest measures with `.rest(duration: .whole)` (e.g. line 11). Tightening the predicate to require `.measure` would invalidate every test in the file; the migration is mechanical and must land together.

- [ ] **Step 1: Write the failing regression test for split rests**

Append to `Tests/SheetMusicTests/MultiMeasureRestPlannerTests.swift` inside the `MultiMeasureRestPlannerTests` suite (before the closing `}` of the struct):

```swift
        @Test("measure with quarter + dotted-half rest is NOT collapsed")
        func splitRestMeasureNotCollapsible() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // 4/4 bar authored as `quarter rest + dotted-half rest`
            // (two empty chords summing to a full measure). MuseScore
            // collapses only true `durationType="measure"` rests; the
            // tightened predicate must reject this composite.
            let split = Measure(voices: [Voice(elements: [
                .rest(duration: .quarter),
                .rest(duration: .fraction(Fraction(numerator: 3, denominator: 4))),
            ])])
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(),
                split,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }
```

- [ ] **Step 2: Run the new test to verify it fails on the current predicate**

Run: `swift test --filter splitRestMeasureNotCollapsible`
Expected: FAIL — the current duration-agnostic predicate collapses across the split-rest measure, so the test sees a single `0 ..< 5` run instead of `[0 ..< 2, 3 ..< 5]`.

- [ ] **Step 3: Migrate `restMeasure()` helper to use `.measure`**

In the same file, change the `restMeasure()` helper at lines 10–12:

```swift
        private static func restMeasure() -> Measure {
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        }
```

Also update any inline `.rest(duration: .whole)` in tests where the intent is "a measure-filling rest" (not a generic typed whole rest). Walk every test in the file and convert per intent:

- `.rest(duration: .whole)` standalone in a measure → `.rest(duration: .measure)` (these were placeholders for full-bar rests).
- `.rest(duration: .whole)` paired with another voice element (e.g. `[.spanner(...), .rest(duration: .whole)]` in `openSpannerBlocksCollapse`) → `.rest(duration: .measure)` (still a full-bar rest; the spanner doesn't change that).
- `keyChange` / `tsChange` measures (lines 126, 144) — keep the `.whole`. These measures aren't pure rest-only bars; they intentionally contain a key/time-sig change plus a typed rest. The predicate already rejects them via the key/time signature, so the typed rest spelling doesn't matter for collapsibility, and converting would muddle test intent.

  Actually re-check: the spec collapses only when every voice element is a `.measure` rest, structural shift, or visual barline. A `.keySignature(...)` voice element is none of these — it falls into the `default: return false` branch. So those tests still pass with `.whole` rests.

- `voiceFinalBarLineDoesNotBreakRun` (line 258) — the `[.rest(duration: .whole), .barLine(...)]` pair → convert the rest to `.measure` so the measure is collapsible. Keep the visual barline as before.
- `locationShiftIsCollapsible` (line 426) — convert `.rest(duration: .whole)` to `.rest(duration: .measure)`.
- `voiceEndRepeatBarLineBreaksRun` (line 238) — convert. The barline still breaks.

- [ ] **Step 4: Tighten the predicate**

In `Sources/SheetMusicLayout/Layout/MultiMeasureRestPlanner.swift` line 152, change:

```swift
                    case let .chord(c) where c.notes.isEmpty:
                        continue
```

to:

```swift
                    case let .chord(c)
                        where c.notes.isEmpty && c.duration == .measure:
                        // MuseScore-aligned: only `.measure` rests
                        // count toward collapse. A measure padded out
                        // with several typed rests is rendered
                        // individually — even if its rests sum to the
                        // full bar.
                        continue
```

- [ ] **Step 5: Run the planner tests**

Run: `swift test --filter MultiMeasureRestPlannerTests`
Expected: all tests pass — including the new `splitRestMeasureNotCollapsible`.

Run: `swift test`
Expected: success.

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/MultiMeasureRestPlanner.swift \
        Tests/SheetMusicTests/MultiMeasureRestPlannerTests.swift
git commit -m "layout: collapse only true .measure rests, matching MuseScore"
```

---

## Task 5: Switch MSCX `<Rest>` decoder to emit `.measure`, migrate MS2 compat tests

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Rest.swift` (lines 21–48)
- Modify: `Tests/SheetMusicTests/MS2CompatibilityTests.swift` (lines 39, 57)

- [ ] **Step 1: Update the MS2 compat assertions to expect `.measure`**

In `Tests/SheetMusicTests/MS2CompatibilityTests.swift`, change line 39:

```swift
        #expect(rest.duration == .measure)
        #expect(
            rest.duration.resolved(in: Fraction(numerator: 5, denominator: 4))
                .asFraction == Fraction(numerator: 5, denominator: 4),
        )
```

…and line 57 the same way.

(The `<duration>` element is now informational under the new model — the decoder no longer needs to inspect it. The paired `resolved(in:)` assertion proves the marker still produces the right effective fraction when given the bar's actual duration.)

- [ ] **Step 2: Run the migrated tests to verify they fail on the current decoder**

Run: `swift test --filter MS2CompatibilityTests/measureRest`
Expected: FAIL — the decoder still emits `.fraction(5/4)`, not `.measure`.

- [ ] **Step 3: Update the decoder to emit `.measure`**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Rest.swift`, replace the function body (lines 21–48) with:

```swift
    private static func duration(
        forDurationType type: String, node: XMLTreeNode,
    ) throws -> NoteDuration {
        if type == "measure" {
            // The `<duration>` child is informational under the
            // `.measure` marker model — encoders re-derive it from
            // the containing measure's effective duration. We accept
            // both the MS3+ slash form (`<duration>N/D</duration>`)
            // and the MS2 attribute form (`<duration z="N" n="D"/>`)
            // by reading-and-discarding either.
            return .measure
        }
        guard let base = NoteDuration(mscxName: type) else {
            throw SheetMusicError.malformedScore(
                reason: "Rest unknown durationType \"\(type)\"",
            )
        }
        let dots = Int(node.first("dots")?.text ?? "0") ?? 0
        return base.dotted(dots)
    }
```

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: success — including the migrated MS2 compat tests, the `MidiExportTests` semantic-equivalence suite (the encoder + tick-walker work in Tasks 2/3 keeps round-trip behaviour intact), and the `MultiMeasureRestPlannerTests` (now the parser produces `.measure` so real fixtures collapse correctly).

Run: `swift test --filter MidiExportTests`
Expected: all 12 cases pass — confirms byte-for-byte SMF semantic-equivalence with MuseScore is preserved.

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Rest.swift \
        Tests/SheetMusicTests/MS2CompatibilityTests.swift
git commit -m "mscx: read full-measure rests as .measure marker"
```

---

## Task 6: Switch MSCX `<RepeatMeasure>` / `<MeasureRepeat>` decoder to emit `.measure`

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+MeasureRepeat.swift` (lines 8–17)

- [ ] **Step 1: Update the decoder**

Replace lines 8–17 of `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+MeasureRepeat.swift`:

```swift
        let durationText = node.first("durationType")?.text ?? "measure"
        let duration: NoteDuration
        if durationText == "measure" {
            // `<duration>` is informational; the encoder re-derives
            // it from the measure's effective duration.
            duration = .measure
        } else {
            duration = NoteDuration(mscxName: durationText)
                ?? .measure
        }
        return MeasureRepeat(numMeasures: num, duration: duration)
```

(Falling back to `.measure` instead of `.fraction(4/4)` for an unknown `durationType` is conservative — it asserts "this is a full-bar repeat" and lets the encoder re-derive the actual length, rather than silently fixing 4/4.)

- [ ] **Step 2: Update the MeasureRepeat encoder to thread effective duration**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+MeasureRepeat.swift`, the encoder is called from `MSCXEncoder+Voice.swift`'s element switch (line 299–300). Update the encoder signature:

```swift
    func encode(
        options: MSCXEncoderOptions = .init(),
        in measureDuration: Fraction = Fraction(numerator: 4, denominator: 4),
    ) -> XMLTreeNode {
        let elementName: String
        var children: [XMLTreeNode] = []
        switch options.targetVersion {
        case .v2, .v3:
            elementName = "RepeatMeasure"
            children.append(XMLTreeNode(name: "linkedMain"))
        case .v4:
            elementName = "MeasureRepeat"
            children.append(XMLTreeNode(
                name: "subtype", text: String(numMeasures),
            ))
        }
        let resolved = duration.resolved(in: measureDuration)
        if case let .fraction(f) = resolved {
            children.append(XMLTreeNode(name: "durationType", text: "measure"))
            children.append(XMLTreeNode(
                name: "duration",
                text: "\(f.numerator)/\(f.denominator)",
            ))
        } else {
            resolved.appendDurationXML(to: &children)
        }
        return XMLTreeNode(name: elementName, children: children)
    }
```

(Replaces the precondition trap added in Task 1 step 10. Now the encoder resolves before encoding.)

In `MSCXEncoder+Voice.swift`'s switch (line 299), pass the effective duration:

```swift
        case let .measureRepeat(measureRepeat):
            return measureRepeat.encode(options: options, in: effectiveDuration)
```

- [ ] **Step 3: Build and test**

Run: `swift build && swift test`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+MeasureRepeat.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+MeasureRepeat.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift
git commit -m "mscx: read measure-repeats as .measure marker; resolve at encode time"
```

---

## Task 7: Switch MusicXML `<rest measure="yes"/>` to emit `.measure`

**Files:**
- Modify: `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift` (around line 36)

- [ ] **Step 1: Detect the `measure="yes"` attribute on `<rest>`**

In `MusicXMLNoteDecoder.decodeNote(...)`, after the existing `let isRest = node.children.contains(...)` check, look at the rest node's attribute. Replace lines 36–38:

```swift
        if isRest {
            let restNode = node.children.first(where: { $0.name == "rest" })
            let isMeasureRest = restNode?.attributes["measure"] == "yes"
            if isMeasureRest {
                // `<duration>` (which `MusicXMLDuration.decode` already
                // consumed for divisions-cursor correctness) is
                // informational under the `.measure` marker model.
                return .new(prefix + [.rest(duration: .measure)])
            }
            return .new(prefix + [.rest(duration: duration)])
        }
```

- [ ] **Step 2: Add a regression test**

Append to `Tests/SheetMusicTests/MusicXMLImportTests.swift` (or whichever existing MusicXML import test file is closest in scope — check via `find Tests -name "MusicXML*"`. If none exists, create `Tests/SheetMusicTests/MusicXMLMeasureRestImportTests.swift` with a single `@Test`):

```swift
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
@testable import SheetMusicXMLTools
import Testing

struct MusicXMLMeasureRestImportTests {
    @Test func restMeasureAttributeProducesMeasureMarker() throws {
        let xml = """
        <score-partwise>
          <part-list>
            <score-part id="P1"><part-name>Test</part-name></score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>4</divisions>
                <time><beats>3</beats><beat-type>4</beat-type></time>
              </attributes>
              <note>
                <rest measure="yes"/>
                <duration>12</duration>
              </note>
            </measure>
          </part>
        </score-partwise>
        """
        let score = try MusicXMLParser.parse(Data(xml.utf8))
        let measure = score.parts[0].staves[0].measures[0]
        let rest = measure.voices.flatMap(\.elements).compactMap { el -> Chord? in
            if case let .chord(c) = el, c.notes.isEmpty { return c }
            return nil
        }.first
        try #require(rest != nil)
        #expect(rest?.duration == .measure)
    }
}
```

- [ ] **Step 3: Build and test**

Run: `swift test --filter MusicXMLMeasureRestImportTests`
Expected: pass.

Run: `swift test`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift \
        Tests/SheetMusicTests/MusicXMLMeasureRestImportTests.swift
git commit -m "musicxml: import <rest measure=\"yes\"/> as NoteDuration.measure"
```

---

## Task 8: Add the meter-change-preserves-measure-rest regression test

**Files:**
- Create: `Tests/SheetMusicTests/MeterChangePreservesMeasureRestTests.swift`

- [ ] **Step 1: Write the test**

```swift
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct MeterChangePreservesMeasureRestTests {
    /// Per spec §"Time-signature changes and measure-rest identity":
    /// a `.measure` rest re-resolves against whatever meter is in
    /// scope at render time. Construct a Score with three identical
    /// `.measure` rests, then run it under 4/4 and again under 3/4
    /// (only the first measure's TimeSignature differs); the MIDI
    /// renderer should produce 3 × bar-length ticks in each case,
    /// scaling automatically with the meter.
    @Test func measureRestTickCountTracksPrevailingMeter() throws {
        let division = 480

        func makeScore(numerator: Int, denominator: Int) -> Score {
            let firstMeasureElements: [VoiceElement] = [
                .timeSignature(TimeSignature(
                    numerator: numerator, denominator: denominator,
                )),
                .rest(duration: .measure),
            ]
            let restMeasure = Measure(voices: [Voice(elements: [
                .rest(duration: .measure),
            ])])
            let measures = [
                Measure(voices: [Voice(elements: firstMeasureElements)]),
                restMeasure,
                restMeasure,
            ]
            return Score(
                division: division,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
                systemMeasures: Array(
                    repeating: SystemMeasure(), count: measures.count,
                ),
            )
        }

        // Resolution check via the helper directly: we don't depend
        // on the MIDI renderer to verify the model behaviour.
        let fourFour = makeScore(numerator: 4, denominator: 4)
        let threeFour = makeScore(numerator: 3, denominator: 4)

        let f4 = fourFour.effectiveMeasureDurations()
        let f3 = threeFour.effectiveMeasureDurations()
        #expect(f4 == Array(repeating: Fraction(numerator: 4, denominator: 4), count: 3))
        #expect(f3 == Array(repeating: Fraction(numerator: 3, denominator: 4), count: 3))

        // Each measure in 4/4 resolves to 4 quarters = 4 * division ticks.
        // Each measure in 3/4 resolves to 3 quarters = 3 * division ticks.
        let totalTicks4 = f4.reduce(0) { acc, frac in
            acc + NoteDuration.measure
                .resolved(in: frac)
                .ticks(division: division)
        }
        let totalTicks3 = f3.reduce(0) { acc, frac in
            acc + NoteDuration.measure
                .resolved(in: frac)
                .ticks(division: division)
        }
        #expect(totalTicks4 == 3 * 4 * division)
        #expect(totalTicks3 == 3 * 3 * division)
    }
}
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter MeterChangePreservesMeasureRestTests`
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests/MeterChangePreservesMeasureRestTests.swift
git commit -m "tests: meter-change preserves .measure rest semantics"
```

---

## Task 9: Final validation

- [ ] **Step 1: Full test sweep**

Run: `swift build`
Expected: success.

Run: `swift test`
Expected: success — every existing test plus all new tests pass.

Run: `swift test --filter MidiExportTests`
Expected: all 12 MuseScore-equivalence cases pass (the canary for round-trip parity).

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors.

- [ ] **Step 2: Verify the example apps still build**

Run: `cd Example && xcodegen generate`
Run: `xcodebuild -project Example/SheetMusicExample.xcodeproj -scheme SheetMusicExample -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: success.

If a Mac scheme exists (`SheetMusicExampleMac`), build it too — the `feedback_example_app_outside_swiftpm` memory notes that public-enum changes need both iOS and Mac xcodebuild verification.

- [ ] **Step 3: Visual regression spot-check (manual, optional but recommended)**

Per `feedback_visual_verify_mac` memory, use `SheetMusicExampleMac` to eyeball a 6/4 fixture (e.g. anything in `Tests/SheetMusicTests/Resources/` with a 6/4 measure-filling rest — `find Tests -name "*.mscx"` and grep `<TimeSig>` for `<sigN>6</sigN><sigD>4</sigD>`). The whole rest should now hang from staff line 4 with NO augmentation dot. Compare against MuseScore for parity.

This step is a sanity check; a passing test suite is the primary gate.

---

## Self-Review Checklist (run before handing off)

**Spec coverage:**
- §"6/4 dotted-rest bug" → Task 1 (DurationInterpretation short-circuit) + Task 9 visual check.
- §"Time-signature changes and measure-rest identity" → Task 1 (`resolved(in:)` + `effectiveMeasureDurations`) + Task 8 (regression test).
- §"MusicXML round-trip parity" → Task 7 (decoder) + Task 7 step 2 (regression test). Export side is intentionally omitted because no `MusicXMLExporter` exists in the package today; the spec mentions it speculatively. Add an explicit follow-up if the exporter lands.
- §"Collapse alignment" → Task 4 (predicate tightening + tests).
- §"Goals 1–6" → Tasks 1, 5, 6, 7 (parsers) + Task 3 (encoder) + Task 1 (split fix) + Task 4 (collapse) + Tasks 5, 8, 4 (test migration / additions).
- §"Non-goals" — confirmed not implemented (no rest-only type, no editor support, no auto-conversion of `.fraction` to `.measure`).
- §"Open questions" — none.
- §"Out-of-scope follow-ups" — leave for separate work; do NOT touch in this plan. Update the `project_feature_gaps_checklist` memory only after the plan ships if any new follow-ups were uncovered (e.g. MusicXML exporter measure-rest support).

**Placeholder scan:** No "TBD" / "implement later" / "add error handling" / "similar to Task N" — every step shows the actual code or command.

**Type consistency:**
- `Score.effectiveMeasureDurations(partIndex:staffIndex:)` — used identically across Tasks 1, 2, 3, 8.
- `NoteDuration.resolved(in:)` — single signature, used identically across Tasks 1, 2, 3, 6, 8.
- `VoiceElement.tickCount(division:in:)` — added in Task 1; the existing `tickCount(division:)` is preserved, not renamed.
- `appendDurationXML(to:in:)` overload — added in Task 3 step 1, used by Task 3 step 2.
- `Chord.encodeAsRest(options:in:)` — added in Task 3 step 2, used by Task 3 step 3.
- `Measure.encode(...)` / `Voice.encode(...)` / `Staff.encodeTopLevel(...)` — `effectiveDuration` / `effectiveMeasureDurations` parameter names consistent across Tasks 3 and 6.

---

## Execution notes for the implementer

- Follow `superpowers:test-driven-development` for new tests: write the failing test before its implementation, run to confirm failure, then implement, then confirm pass.
- Follow `superpowers:verification-before-completion` between tasks: do not check off a step until `swift build && swift test` actually succeed locally.
- Use `superpowers:systematic-debugging` if a test that should pass fails — particularly during Task 5 (decoder switch), where mis-resolved `.measure` causes `preconditionFailure` traps that are easy to mistake for crashes.
- Per `feedback_swift_enum_case_addition_scope` memory: Task 1 must land as a single commit. Do not split the foundation across multiple commits — every public-enum exhaustive switch in the package must be updated in lockstep.
- Per `feedback_example_app_outside_swiftpm` memory: Task 9 step 2 is mandatory, not optional. Public-enum changes can break the example app even when `swift test` is green.
