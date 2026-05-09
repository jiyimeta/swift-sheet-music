# Multi-Measure Rest — Design

Date: 2026-05-10

## Summary

Add a display-time option that collapses runs of consecutive rest
measures into a single multi-measure-rest bar (the "H-bar" with a
count above it). The option lives on `ScoreViewOptions` and only
affects layout / rendering — the underlying `Score` model and MIDI
export are untouched. Default is `.disabled` (every rest measure
renders individually, matching today's behavior).

## Motivation

Multi-measure rests are a standard notation device used in part
scores (e.g. one instrument's part within an ensemble): `N` empty
bars are condensed into a single bar containing a thick horizontal
beam (`restHBar` in SMuFL) with the number `N` printed above. They
make long stretches of silence readable without burning page space
on identical empty bars.

`swift-sheet-music` already exposes the data needed to detect a
collapsible run (`Measure.voices`, `markers`, `jumps`,
`startRepeat` / `endRepeatCount`, `lineBreak` / `pageBreak`,
`measureRepeatCount`, `irregular`, `actualLength`), and the
rendering layer already references `restHBar` in
`SMuFLGlyph.swift`. What's missing is the policy + the
collapse pass + the corresponding renderer / extents path.

## Non-goals

- Changing the `Score` data model. The collapse is a layout-time
  view of the score; `Measure` keeps its individual entries.
- Affecting `SheetMusicMIDI` output. A collapsed run plays exactly
  the same as the un-collapsed run (silence is silence).
- Changing the MSCX read or write path. We do not currently parse
  MuseScore's `<multiMeasureRest>` style flag, and we do not need
  to in order to ship this feature; the option is independently
  controllable from the host app.
- Per-staff / per-part policies. Policy is document-wide.
- Configurable run-break rules. Rules are hard-coded to mirror
  MuseScore's behavior (see "Run-break rules" below). If publishers
  later need different rules, we can lift them into a richer policy
  type without breaking the v1 API.
- An auto-tuned collapsed-bar width based on `log(N)` or similar.
  v1 uses a single fixed width derived from `staffSize`; we can
  tune later without API churn.

## Public API

### `MultiMeasureRestPolicy`

New public enum, declared next to `LayoutBreakPolicy` in
`Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`:

```swift
@available(macOS 15.0, iOS 16.0, *)
public enum MultiMeasureRestPolicy: Sendable, Equatable {
    /// Default — every rest measure renders individually.
    case disabled

    /// Collapse runs of `>= minimumMeasures` consecutive rest
    /// measures into one H-bar. Typical value is 2.
    /// Values < 2 are clamped to 2 by the planner.
    case collapse(minimumMeasures: Int)
}
```

The enum-with-associated-value shape (rather than
`(enabled: Bool, minimumMeasures: Int)`) makes invalid states
unrepresentable and matches the existing `LayoutBreakPolicy`
shape on the same struct.

### `ScoreViewOptions`

One new field, with a default-additive initializer change:

```swift
public var multiMeasureRest: MultiMeasureRestPolicy

public init(
    staffSize: CGFloat = 28,
    systemGap: CGFloat = 40,
    wrapToViewWidth: Bool = true,
    includeTitleFrame: Bool = true,
    breakPolicy: LayoutBreakPolicy = .honor,
    showBreakIndicators: Bool = true,
    graceNoteMag: CGFloat = 0.6,
    multiMeasureRest: MultiMeasureRestPolicy = .disabled
) { … }
```

Default `.disabled` keeps every existing call site
behavior-compatible. The struct stays `Sendable & Equatable`.

## Run-break rules

"Measure `M`" below means *the tuple of `M_i`s at index `i` across
every staff in the score*. A measure index `i` is **collapsible**
iff, for every staff `s`, the conditions hold on `s.measures[i]`:

1. For every `voice` in `s.measures[i].voices`:
   - Every `element` in `voice.elements` is either `.chord(c)` with
     `c.notes.isEmpty` (i.e. a rest), or `.locationShift(...)`
     (purely a cursor jog, which has no visual effect on a rest
     bar).
   - `voice.tuplets.isEmpty` (a tuplet over rests is unusual but
     not collapsible — it carries a bracket / number).
2. `M.startRepeat == false`, `M.endRepeatCount == nil`.
3. `M.markers.isEmpty`, `M.jumps.isEmpty`.
4. `M.measureRepeatCount == nil` (we never collapse across or into a
   measure-repeat group).
5. `M.irregular == false`, `M.actualLength == nil` (irregular bars
   and length overrides break the run).
6. No spanner (hairpin, slur, ottava, …) is currently active across
   `M`. A collapsible measure must contain no `.spanner(...)` in any
   voice, and no spanner started in an earlier measure remains open
   at `M`. The planner determines this by walking measures in order
   and tracking open-spanner depth (incremented on a spanner whose
   `tick2 > tick1`, decremented at the matching end).
7. No tie crosses into or out of `M`. Since rest measures contain no
   notes, the only way a tie can be live across `M` is if it
   started in a sounding measure and is closed later — but a tie's
   destination must be a note, so this is structurally impossible
   for a measure that contains only rests. Documented here for
   completeness; no extra check needed.

A **run** is a maximal sequence of collapsible measures `M_i ..
M_{i+k-1}` such that, additionally, on every interior boundary:

8. The previous measure does not have `lineBreak == true` or
   `pageBreak == true` (an authored break closes the run; the
   collapse never spans a system).
9. The collapsible-measure check at `M_{i+k}` itself fails (i.e. we
   stop at the first non-collapsible measure or at the end of the
   score).

A run is **emitted as collapsed** iff its length `k` satisfies
`k >= max(2, minimumMeasures)`. Shorter runs render as individual
measures (unchanged behavior).

These conditions intentionally mirror MuseScore's
`Score::createMMRest` predicate without adopting it line-for-line;
the doc comments on each predicate cite the C++ source for
auditability.

## Architecture

### New file: `MultiMeasureRestPlanner.swift`

`Sources/SheetMusicLayout/Layout/MultiMeasureRestPlanner.swift`. A
pure function over `Score` and `MultiMeasureRestPolicy`:

```swift
@available(macOS 15.0, iOS 16.0, *)
struct MultiMeasureRestPlan: Sendable, Equatable {
    /// Sorted, non-overlapping ranges of measure indices that
    /// should render as a single collapsed bar.
    ///
    /// `Range.lowerBound` is the first collapsed measure (where
    /// the H-bar is drawn); `Range.upperBound` is one past the
    /// last collapsed measure. Measures inside the half-open range
    /// are skipped by the layout pass.
    let runs: [Range<Int>]

    /// Convenience: returns the run that contains `measureIndex`,
    /// or `nil` if the measure renders individually.
    func run(containing measureIndex: Int) -> Range<Int>?
}

@available(macOS 15.0, iOS 16.0, *)
enum MultiMeasureRestPlanner {
    static func plan(
        for score: Score,
        policy: MultiMeasureRestPolicy
    ) -> MultiMeasureRestPlan
}
```

`plan(for:policy:)` returns an empty plan immediately when
`policy == .disabled`. Otherwise it walks measures once, tracking
open-spanner depth, and emits runs whose length meets the
threshold.

A `Score` carries one `Measure[]` array per `Staff`
(`score.parts[*].staves[*].measures`); all arrays share the same
length and the same index space. The planner zips them at each
measure index `i` and treats `M_i` as collapsible **only if every
staff's `M_i` is collapsible** under rules 1–7 *and* the open
spanners across **all staves** are zero at that index. Conditions
2–5 (`startRepeat`, `markers`, `irregular`, …) are typically
identical across staves of a given measure index in well-formed
MuseScore output, but the planner does not assume that — it checks
each staff independently.

### Layout integration

`LayoutEngine` (`+SystemBuild.swift`) already iterates measures.
The integration is minimal:

1. Compute the plan once at the top of the layout pass:
   `let plan = MultiMeasureRestPlanner.plan(for: score, policy:
   options.multiMeasureRest)`.
2. When the iterator reaches measure index `i`:
   - If `plan.run(containing: i)?.lowerBound == i` → emit one
     `LayoutMeasure` of kind `.multiMeasureRest(count: range.count)`
     with the fixed collapsed width (see "Width" below). Set the
     iterator's next position to `range.upperBound`.
   - Else if `plan.run(containing: i) != nil` → skip; the
     enclosing run already emitted the bar.
   - Else → emit the measure normally.

`LayoutMeasure` gains a new variant. Today `LayoutMeasure` is a
struct (not an enum); we add an optional payload field rather than
re-modeling the whole type:

```swift
struct LayoutMeasure {
    // … existing fields …

    /// When non-nil, this layout-measure renders as an H-bar
    /// covering `multiMeasureRest!` original measures. The
    /// `voices` / `events` arrays are empty in that case (the
    /// renderer ignores them).
    var multiMeasureRest: Int?
}
```

The planner-driven skip means downstream code (system builder,
spanner layout, ties) never sees the skipped measures; spanners
that legitimately end inside a run are already excluded by the
collapsibility predicate (rule 6).

### Width

A collapsed bar's width is computed in
`LayoutEngine+Spacing.swift`:

```swift
// Fixed width for v1. ~6 staff-spaces feels right against
// MuseScore's default mmRest bar; we can tune by measurement.
let collapsedWidth = 6 * staffMetrics.staffSpace
```

The width does **not** scale with `count` in v1. Empirically the
H-bar reads fine at a fixed width regardless of `N`; the count
above the bar conveys the magnitude. We can add a `log(N)` taper
later behind the same field without API churn.

### Rendering

A new file `Sources/SheetMusicUI/Rendering/MultiMeasureRestView.swift`
draws:

- The `restHBar` SMuFL glyph horizontally centered in the bar,
  vertically centered on the middle staff line. The glyph is a
  single thick beam; SMuFL's bounding box is wider than 1 em — we
  scale it to fit `collapsedWidth - 2 * margin`.
- Two short vertical "serif" caps at the ends of the bar (SMuFL
  `restHBarLeft` / `restHBarRight` if present in the loaded font;
  Bravura provides them).
- The count `N` rendered as bold tempo-style text centered above
  the bar at `y = staffTop - 0.5 * staffSpace`.

`LayoutEngine+Emit.swift` emits a corresponding `LayoutElement`
case (`.multiMeasureRest(count: Int)`) that the renderer dispatches
on.

### Selection / cursor

Selection and the playback cursor address measures by index. When
the cursor's tick falls inside a collapsed run:

- `PlaybackCursorView` advances continuously across the H-bar at
  the run's average tick rate. The bar's `x` extent is the layout
  measure's frame; the cursor uses `tickAt(measureIndex: lower) +
  fractionAcrossRun * runTickSpan`.
- Tap-to-select on the H-bar selects the run's first measure
  (matches MuseScore's behavior).

These cursor / selection details are noted here for completeness
but live in the implementation plan, not in the public API.

## Testing

Pure-logic tests live in
`Tests/SheetMusicTests/MultiMeasureRestPlannerTests.swift` (Swift
Testing). Cases:

1. `disabled_returnsEmptyPlan`
2. `runOfThreeRestMeasures_collapsesWhenMinimumIsTwo`
3. `runOfTwoRestMeasures_doesNotCollapseWhenMinimumIsThree`
4. `rehearsalMarkBreaksRun` — `[rest, rest, restWithRehearsalMark,
   rest]` → no collapse before the mark; the mark-bearing measure
   is non-collapsible; the trailing rest is a 1-measure run (no
   collapse).
5. `keySignatureChangeBreaksRun` — `[rest, rest+keyChange, rest,
   rest]` → first two count as a 2-rest run only if the key change
   is on `M_2`'s leading edge (it is, because key sigs are voice
   elements at the start of a measure). The measure carrying the
   change is non-collapsible; the trailing pair collapses.
6. `timeSignatureChangeBreaksRun` — analogous.
7. `tempoChangeBreaksRun` — analogous.
8. `repeatStartBreaksRun`, `repeatEndBreaksRun`, `markerBreaksRun`,
   `jumpBreaksRun`.
9. `lineBreakClosesRun`, `pageBreakClosesRun`.
10. `irregularMeasureNotCollapsible`,
    `actualLengthOverrideNotCollapsible`.
11. `measureRepeatGroupNotCollapsible`.
12. `openSpannerBlocksCollapse` — a hairpin starting in `M_0` and
    ending in `M_3` blocks `M_1..M_2` from collapsing even though
    they are individually rests.
13. `locationShiftAlone_isCollapsible` — a `.locationShift` with
    no other element does not break the run.

Layout integration tests:

14. `layoutEngine_emitsSingleMeasure_forCollapsedRun` — render a
    6-measure score with 4 consecutive rest measures and assert the
    `LayoutSystem` contains 3 layout measures (sounding, H-bar,
    sounding).
15. `layoutEngine_disabled_emitsEveryMeasure` — same input,
    `.disabled` policy, assert 6 layout measures.

Visual verification: a `#Preview` in
`Sources/RenderPreviews/MultiMeasureRestPreview.swift` covering
(a) collapsed run of 8 measures, (b) `.disabled` baseline,
(c) run interrupted mid-stream by a rehearsal mark. Verified via
`mcp__xcode__RenderPreview` per the iOS preview-first workflow.

The `MidiExportTests` corpus is unaffected (no MIDI semantics
change). No new fixture files needed; we synthesize scores in-test.

## Migration / compatibility

- All public additions are default-additive. No call site needs to
  change.
- `Sendable` and `Equatable` conformance preserved on
  `ScoreViewOptions` (enum with associated `Int` is both).
- The `LayoutMeasure.multiMeasureRest: Int?` addition is
  internal-by-default; it doesn't appear on the public API
  surface.

## Open questions

None blocking implementation. Two future-work items:

- **MuseScore round-trip**: when we add `<multiMeasureRest>`
  parsing to `SheetMusicMSCX`, the parsed flag should drive the
  same option (or be reflected onto a `Score`-level hint that the
  policy can default to). v1 ignores it.
- **Width tuning**: a `log(N)` taper or per-style "min mm-rest
  width" would be more faithful. v1's fixed width is good enough
  to ship.
