# NoteDuration `.measure` — Design

Date: 2026-05-15

## Summary

Add a `.measure` case to `NoteDuration` so the model can represent
"this rest fills the containing measure" as a semantic marker
rather than as a concrete fraction. The `.measure` value carries no
duration of its own; consumers resolve it against the measure's
effective duration (its `actualLength` override, or the prevailing
`TimeSignature`) at the point of use.

This corrects the long-standing rendering bug where a 6/4
measure-filling rest is drawn as a *dotted* whole rest, brings the
model in line with MuseScore's `DurationType::V_MEASURE` and
MusicXML's `<rest measure="yes"/>`, and unlocks correct round-trip
behaviour when the prevailing time signature changes later in the
score (the rest stays "measure-filling" instead of being pinned to
the original meter).

While we are touching the area, tighten the existing multi-measure
rest collapse predicate so it requires every collapsible voice's
rest-shaped element to be specifically a `.measure` rest — matching
MuseScore's behaviour. The current predicate is duration-agnostic
and will collapse a measure whose voice content sums to the full
measure via several smaller rests, which MuseScore does not.

## Motivation

### The 6/4 dotted-rest bug

In 6/4 time, a measure-filling rest should render as a single whole
rest hanging from staff line 4, with no augmentation dot — the
SMuFL `restWhole` glyph (U+E4E3) is used universally for
measure-filling rests regardless of meter. MuseScore behaves this
way; we currently do not.

The MSCX parser reads
`<Rest><durationType>measure</durationType><duration>6/4</duration></Rest>`
into `NoteDuration.fraction(6/4)`. At render time,
`DurationInterpretation.split()` reduces 6/4 to 3/2, recognises 3
as the dotted-pattern numerator (`2^(d+1) − 1` for `d=1`), and
returns `(.whole, 1)` — a dotted whole. The renderer then draws an
augmentation dot next to the whole rest glyph.

The same heuristic also miscategorises 3/4 (→ dotted half), 6/8
(→ dotted half), and 12/8 (→ dotted whole) measure-filling rests.
9/8 happens to escape the bug because the heuristic's dotted
pattern (`2^(d+1) − 1`) does not match 9 — control falls through
to the power-of-two-denominator fallback at
`DurationInterpretation.swift:47-51`, which correctly returns
`(.whole, 0)`. The general rule of which meters are broken: any
whose reduced numerator equals `2^(k+1) − 1` for some `k ≥ 1`.
The existing test suite (`DurationInterpretationTests`) does not
cover any of these.

### Time-signature changes and measure-rest identity

MuseScore preserves measure-rest identity across time-signature
changes. Three 4/4 bars of `<durationType>measure</durationType>`
re-saved with a 3/4 time signature become four 3/4 bars of
measure-rest — not a re-decomposed `quarter rest + half rest |
half rest + quarter rest | …` sequence.

This is only expressible if the rest's duration is *relative* to
the containing measure. A fixed `.fraction(4/4)` would have to be
re-split. A `.measure` marker simply re-resolves against the new
measure's effective duration on the next pass through the renderer
/ exporter.

`swift-sheet-music` has no in-package editor that swaps a time
signature mid-score today, but the test target can construct such
a `Score` programmatically, and downstream consumers (e.g. the
in-flight note-input mode) will hit this case as soon as they let
the user change a meter.

### MusicXML round-trip parity

MusicXML encodes a full-measure rest as `<rest measure="yes"/>`
inside `<note>`, paired with a numeric `<duration>` for playback.
The boolean attribute is the authoritative semantic marker; the
numeric duration is informational. Without `.measure` in the
model, an import → export round-trip loses the `measure="yes"`
flag and rewrites the rest as a plain typed rest.

### Collapse alignment

`MultiMeasureRestPlanner.isCollapsible` currently treats any
empty-`Chord` voice element as "rest-like" regardless of its
duration. This means a measure containing
`quarter rest + dotted-half rest` (two empty chords summing to a
4/4 bar) is treated as collapsible — broader than MuseScore, which
only collapses true `durationType="measure"` rests. The user has
asked for MuseScore-aligned behaviour. With `.measure` in place
the tightening is a one-line predicate change.

## Goals

1. Introduce `NoteDuration.measure` and make it the canonical
   in-memory form of any full-measure rest produced by the MSCX
   parser, the MusicXML importer, the MIDI importer, and the PDF
   importer.

2. Make `MSCXEncoder`, `MusicXMLExporter`, and `MidiRenderer`
   resolve `.measure` against the measure's effective duration so
   external outputs are byte-for-byte equivalent to the current
   `.fraction(...)`-based outputs (except for the 6/4 dot fix and
   the MuseScore-aligned mmrest collapse).

3. Fix the 6/4 (and analogous) dotted-rest rendering by making
   `DurationInterpretation.split(.measure)` return `(.whole, 0)`
   without going through the dotted-pattern heuristic.

4. Align multi-measure rest collapse with MuseScore by requiring
   every voice's rest-shaped element to be a `.measure` rest.

5. Migrate the two MS2 compatibility tests that currently assert
   `rest.duration.asFraction == Fraction(5, 4)` to assert
   `rest.duration == .measure`.

6. Add new tests:
   - `DurationInterpretationTests`: 6/4, 9/8, 12/8 measure rests
     render as `(.whole, 0)`.
   - `MeterChangePreservesMeasureRest` (Core): programmatically
     swap a TimeSignature on a score that contains `.measure`
     rests; verify the resolved MIDI tick count tracks the new
     meter.
   - `MultiMeasureRestPlannerTests`: a measure containing
     `quarter rest + dotted-half rest` (two empty chords) is *not*
     collapsed, while `.measure` rests still collapse.

## Non-goals

- **Splitting `NoteDuration` into note-only and rest-only types.**
  The type system stays as-is; `.measure` is syntactically
  available on notes but parsers/writers never produce it for
  notes. Adding a structural rest type is a much larger refactor
  with churn across every VoiceElement consumer, and the only
  payoff is preventing a misuse no one is making.

- **A `Rest` first-class type.** Rests remain empty `Chord` values
  as today. Touching that representation is independent work.

- **Editor support for swapping a time signature mid-score.** The
  `.measure`-preservation behaviour is verified by programmatic
  construction in tests. An interactive editor surface is a
  separate feature.

- **MuseScore-strict collapse for non-rest voice elements
  (`locationShift`, visual-only `<BarLine>`s).** The existing
  predicate's allowance for these stays. Whether MuseScore
  actually collapses such measures is recorded as a follow-up in
  `project_feature_gaps_checklist.md`.

- **Auto-conversion of existing `.fraction(N/D)` rests to
  `.measure` when N/D happens to equal a measure's actual
  duration.** Conversion happens only at parser boundaries
  (MSCX `durationType="measure"`, MusicXML `measure="yes"`).
  Hand-constructed `Score` instances that use `.fraction(...)`
  for a full-measure rest keep their existing behaviour (still
  collapses pre-`.measure`-tightening: no longer collapses post-
  tightening). Test fixtures that need collapse must use
  `.measure`.

## Design

### Core model — `NoteDuration.measure`

```swift
public enum NoteDuration: Sendable, Equatable {
    case whole, half, quarter, eighth, sixteenth, thirtySecond,
         sixtyFourth, oneTwentyEighth, twoFiftySixth
    case fraction(Fraction)
    case measure
}
```

`.measure` is a marker — it has no intrinsic Fraction. Treat it
the way you would treat a placeholder that must be resolved
against context before any quantitative question can be asked.

### Trap semantics on context-free APIs

`NoteDuration.asFraction` and `NoteDuration.ticks(division:)` are
context-free properties / methods. With `.measure` in the picture
they have no correct answer without a measure context. Two
options were considered:

- **(A) Make them `Optional`.** Forces every caller to handle
  `nil`, but ~60 call sites already deference the result and most
  iterate per-measure, so the unwrap noise dominates the type
  safety win.

- **(B) Make them trap on `.measure`, and require callers that
  might see `.measure` to resolve first.** Chosen. Most call
  sites already have a measure in scope. Adding a single
  `resolved(in:)` at the top of the per-measure loop covers them.

The trap is a `preconditionFailure` so misuse is caught loudly in
debug *and* release builds. The error message names the helper
to use:

```swift
public var asFraction: Fraction {
    switch self {
    case .measure:
        preconditionFailure(
            ".measure has no fixed duration; " +
            "resolve via resolved(in:) first")
    case .whole: return Fraction(numerator: 1, denominator: 1)
    // ...other cases unchanged...
    case let .fraction(f): return f
    }
}

public func ticks(division: Int) -> Int {
    switch self {
    case .measure:
        preconditionFailure(
            ".measure has no fixed tick count; " +
            "resolve via resolved(in:) first")
    // ...other cases unchanged...
    }
}
```

### Resolution helper

```swift
extension NoteDuration {
    /// Replace `.measure` with `.fraction(measureDuration)`.
    /// All other cases pass through unchanged.
    public func resolved(in measureDuration: Fraction) -> NoteDuration {
        switch self {
        case .measure: return .fraction(measureDuration)
        default: return self
        }
    }
}
```

`dotted(_:)` traps when called on `.measure` — augmenting a
marker is musically meaningless and there is no legitimate caller.

### Effective measure duration

A measure's effective duration is:

```
actualLength ?? Fraction(prevailingTS.numerator, prevailingTS.denominator)
```

where `prevailingTS` is the most recent `TimeSignature`
encountered in voice scan order up to and including the start of
this measure. This rule already exists informally throughout the
codebase (used by tick math, beaming, the layout engine).

Add a single helper on `Score` (or as a free function in
`SheetMusicCore`) that produces a per-measure effective-duration
array:

```swift
extension Score {
    /// Effective duration of each measure across the score,
    /// indexed by measure number. Used by encoders / renderers
    /// that need to resolve `.measure` durations.
    public func effectiveMeasureDurations(
        partIndex: Int = 0,
        staffIndex: Int = 0,
    ) -> [Fraction]
}
```

The first part / first staff is sufficient as a TimeSignature
source — TimeSignature changes are score-wide in this model.

### Per-call-site migration

The audit (recorded in conversation, but not duplicated here)
found ~60 `ticks(division:)` calls and ~10 `asFraction` calls.
The migration pattern is mechanical:

```swift
// before
for measure in staff.measures {
    for el in measure.voices.flatMap(\.elements) {
        if case let .chord(c) = el {
            let t = c.duration.ticks(division: division)
            // ...
        }
    }
}

// after
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

Call sites that cannot see `.measure` (e.g. tuplet inner-element
loops, grace-chord paths) skip the resolve. The migration is
done in one pass through the audit list; each touched file gets
its own commit so review is incremental.

`VoiceElement.tickCount(division:)` (the context-free helper at
`Sources/SheetMusicCore/Score/VoiceElement.swift:61-66`) gains a
sibling overload `tickCount(division:in measureDuration:)` that
resolves `.measure` first. The original overload is kept; it
traps via `NoteDuration.ticks(division:)`'s trap when the
element is a `.measure` rest, so misuse is caught loudly.

### Parser changes

#### MSCX (`MSCXDecoder+Rest.swift`)

```swift
// before
if type == "measure" {
    let frac: Fraction = /* parses <duration> */
    return .fraction(frac)
}

// after
if type == "measure" {
    // <duration> is informational under the new model; ignore it.
    // The decoder no longer needs to know the measure's
    // actualDuration — that is the renderer's / encoder's job.
    return .measure
}
```

The `<duration>` element parsing logic is preserved as a function
because the encoder needs the inverse mapping; move it to
`MSCXEncoder+NoteDuration.swift` (or keep a shared helper in
`SheetMusicMSCX/Internal`).

MS2 attribute form (`<duration z="5" n="4"/>`) is read and
discarded the same way.

#### MusicXML (`MusicXMLImporter+Note.swift` / similar)

When `<rest measure="yes"/>` is observed, build a Rest with
`NoteDuration.measure` regardless of the inner `<duration>` value.
The `<duration>` is still consumed so the divisions cursor
advances correctly.

#### MIDI importer

The MIDI importer never produces `.measure` directly — it
quantizes against a chosen grid and emits typed durations. A
post-pass *could* fold a measure full of rest events into a
single `.measure`, but is out of scope here. Existing behaviour
(synthesise a typed rest) is preserved.

#### PDF importer

Same as MIDI: out of scope.

### Encoder / renderer changes

#### `MSCXEncoder+Rest` / `+NoteDuration`

When `chord.notes.isEmpty` and `chord.duration == .measure`,
emit:

```xml
<Rest>
  <durationType>measure</durationType>
  <duration>N/D</duration>   <!-- from effective measure duration -->
</Rest>
```

`<duration>` value comes from the measure's effective duration
(MS3+ slash form). MS2-target export keeps the attribute form
(`<duration z="N" n="D"/>`) under the existing MS-version flag.

#### `MusicXMLExporter`

For a Rest with `.measure`, emit `<rest measure="yes"/>` plus
`<duration>` derived from the effective measure duration in the
prevailing `<divisions>`.

#### `MidiRenderer+Voice.swift`

The voice scan already runs per measure. Resolve `.measure` to
the effective duration at the top of the per-measure loop and
proceed as today.

#### `LayoutEngine+Placement.swift` (and friends)

Same pattern. The tick advance loop resolves `.measure` before
the `chord.duration.ticks(...)` call.

#### `DurationInterpretation.split`

Direct short-circuit before the dotted heuristic runs:

```swift
public static func split(
    _ duration: NoteDuration,
) -> (base: NoteDuration, dots: Int) {
    switch duration {
    case .measure:
        return (.whole, 0)
    case let .fraction(f):
        // ... existing logic, unchanged ...
    // ...
    }
}
```

This single change fixes the 6/4 dotted rest. The dotted-pattern
heuristic is left alone; it only ever sees `.fraction(...)` from
non-measure sources, so its behaviour for genuine dotted notes
written as raw fractions is untouched.

### Collapse tightening (`MultiMeasureRestPlanner.swift`)

The predicate currently accepts any empty chord as rest-like:

```swift
case let .chord(c) where c.notes.isEmpty:
    continue
```

Change to require a measure-rest specifically:

```swift
case let .chord(c) where c.notes.isEmpty && c.duration == .measure:
    continue
```

The other rules (irregular, startRepeat, structural barlines,
spanners, jumps, markers, measureRepeat, lineBreak/pageBreak)
stay as they are.

Update `MultiMeasureRestPlannerTests`:

- Existing tests that authored a measure as a single `.measure`
  rest (likely the majority — they were written to mirror
  MSCX fixtures) continue to pass without change once the
  parser change is in.
- Any test that authored a collapsed measure as
  `[empty Chord with .fraction(N/D)]` directly must switch to
  `.measure` (audit during implementation).
- Add a regression test asserting that a measure containing
  `quarter rest + dotted-half rest` is NOT collapsed.

## Compatibility and migration

### Source-breaking change scope

`NoteDuration` is `public` and gains an enum case. Every
exhaustive switch on `NoteDuration` outside this package breaks.
Inside the package: every exhaustive switch must add a `.measure`
arm. Per `project: feature gaps checklist` memory, the affected
switches must all be enumerated in the implementation plan; no
default branches that silently swallow `.measure`.

In-package switches identified by audit:

- `NoteDuration.swift` — `ticks(division:)`, `asFraction`,
  `dotted(_:)`
- `DurationInterpretation.swift` — `split(_:)`
- `LayoutEngine+Spacing.swift:518` — `case let .fraction(f)`
  surface
- `PDFImporter+Rhythm.swift:219` — `case let .fraction(f)`
  surface
- `MSCXEncoder+NoteDuration.swift:67` — `case let .fraction(f)`
- `MSCXEncoder+MeasureRepeat.swift:31` — `case let .fraction(f)`

Each is updated in the same commit that introduces `.measure` so
the package always builds at every commit boundary.

### Behavioural changes visible to downstream consumers

- **Rendering**: 6/4 (and analogous) measure-filling rests draw
  with no augmentation dot. Matches MuseScore. This is the
  primary user-visible fix.

- **MSCX round-trip**: `.measure` rests round-trip through
  `<durationType>measure</durationType>` exactly as before
  byte-wise. Verified by the existing `MSCXEncoderTests` and the
  `MidiExportTests` semantic-equivalence suite.

- **MIDI playback / audio export**: tick counts of `.measure`
  rests are unchanged because the resolved fraction equals the
  measure's effective duration, which equals the previously
  stored fraction.

- **Multi-measure rest collapse**: collapse coverage shrinks for
  scores that contain split full-measure rests (e.g. a 4/4 bar
  with `quarter + dotted-half`). MuseScore-aligned; no MSCX
  fixture in the repository exhibits this pattern.

### Test fixture impact

No GPL-licensed test fixtures need to change: every fixture rest
is already authored as `<durationType>measure</durationType>`.

Hand-written tests:

- `MS2CompatibilityTests.swift:39, :57` — both currently assert
  `rest.duration.asFraction == Fraction(5, 4)`. Migrate to
  `#expect(rest.duration == .measure)` (and add a paired
  resolution check: `#expect(rest.duration.resolved(in:
  Fraction(5, 4)).asFraction == Fraction(5, 4))`).
- `MultiMeasureRestPlannerTests` — audit during implementation.
- New tests for the 6/4 fix and meter-change preservation per the
  Goals section.

## Open questions

None at design time. The audit confirmed scope; the API choice
(trap + `resolved(in:)`) was selected over Optional return; the
collapse tightening scope is settled at "duration limit only,
locationShift / visual barline allowance untouched".

## Out-of-scope follow-ups (logged in memory)

- Verify MuseScore's actual collapse behaviour for measures
  containing `locationShift` or visual-only `<BarLine>`s and
  tighten further if needed (`project_feature_gaps_checklist.md`,
  2026-05-15 entry).
- Add a post-pass in the MIDI importer that folds an
  all-rest measure into a single `.measure` rest.
- Consider a first-class `Rest` type separate from empty `Chord`
  (independent refactor).
