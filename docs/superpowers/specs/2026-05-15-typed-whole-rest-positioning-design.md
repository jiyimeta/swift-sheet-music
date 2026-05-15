# Typed-Whole Rest Positioning — Design

Date: 2026-05-15

## Summary

Position rests at their start-beat tick. Centre only `.measure`
markers in the bar's chord area.

Today the layout engine centres any rest whose `DurationInterpretation
.split(...)` resolves to `(.whole, 0)` — that includes both
`.measure` markers and typed `.whole` rests (and any
`.fraction(N/D)` value that decomposes to a whole). Now that
`NoteDuration.measure` exists as a first-class case, the centring
heuristic should narrow to that case alone. Typed `.whole` rests
flow through `timedX(atTick:)` like every other duration.

## Motivation

The change reflects MuseScore's data model: a "centred" rest is
authored as `<durationType>measure</durationType>`, not
`<durationType>whole</durationType>`. Before
`NoteDuration.measure` landed, the renderer had no way to tell the
two apart and treated all `.whole`-glyph rests as measure-fills. The
heuristic produced correct visuals for the common case (4/4 bars
with a single full-bar rest) but broke down for irregular meters:

- **6/4 with `whole + half`** — the writer intends a 4-beat rest
  followed by a 2-beat rest, occupying the whole bar in two pieces.
  Today both render at the bar's centre, sharing an X coordinate
  and visually colliding. After this change, the whole rest sits
  on beat 1 and the half rest on beat 5, matching the meter.
- **5/4 with `whole + quarter` (or analogous splits)** — same
  problem, different denominator.
- **Voice-2 `.whole` rest "alongside" voice-0 melody** — today this
  centres to balance with voice 0. After the change, the typed
  `.whole` lands at tick 0, overlapping voice 0's first chord.
  Authors who want the centred behaviour should switch to
  `.measure` (the MuseScore-canonical spelling). This is a
  deliberate behavioural change agreed with the user — see Goals.

## Goals

1. `.measure` rests render with the `restWhole` glyph, hung from
   staff line 4, **centred** in the chord area as today.
2. Every other rest (typed `.whole`, `.half`, `.quarter`, …, plus
   any `.fraction(N/D)` that happens to decompose to a whole)
   positions at `timedX(atTick: cursor)` — its start beat.
3. Add a regression test: a 6/4 bar containing
   `[.whole rest, .half rest]` resolves to a whole rest at beat 1
   and a half rest at beat 5, with the half rest's X strictly
   greater than the whole rest's X.
4. Migrate the existing
   `MultiStaffAlignmentTests/Voice-1 whole rest centers in the
   measure` fixture from `.rest(duration: .whole)` to
   `.rest(duration: .measure)` so the test continues to assert the
   spec-correct intent ("a measure-filling rest in voice 1
   centres") rather than the old shortcut ("any whole-glyph rest
   centres"). Test logic stays the same.

## Non-goals

- **Vertical positioning (`restY`).** Typed `.whole` rests still
  hang from staff line 4 and still get the `restWholeLegerLine`
  variant when pushed off the staff by `restVoiceOffset`.
  Unchanged.
- **Width allocation.** `LayoutEngine+Spacing.durationWidth`
  already returns `quarters = 4` for both `.measure` and `.whole`,
  and the per-tick spacing layer (`aggregatedTickWeights`) already
  allocates width by duration. No change.
- **Multi-measure rest collapse.** Already requires `.measure` per
  Task 4 of the prior spec. Unchanged.
- **Multi-voice "centre voice 2 if voice 1 carries content"
  heuristic.** Removed by this change. Authors who want that
  visual must use `.rest(duration: .measure)`. The current
  shortcut is dropped.
- **Migrating MSCX `<durationType>whole</…>` rests to `.measure`
  on import.** No — the parser preserves the file's distinction.
  A `.whole` in the input means a typed whole rest in the output;
  a `.measure` in the input means a measure-fill marker. Round-trip
  is exact.

## Design

### One-place change

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`,
the rest-X branch around lines 500–517:

```swift
// Today
let isWholeRest = restBase == .whole
let restX: CGFloat
if isWholeRest {
    let trailingPad = metrics.sp * 1
    restX = (
        headerSchedule.contentStartX
            + width - trailingPad,
    ) / 2
} else {
    restX = timedX(atTick: tickCursor)
}
```

becomes:

```swift
// Centre only true measure-fill markers (.measure). Typed
// whole rests carry an explicit duration and sit on their
// start beat — MuseScore's data model: a "centred" rest in
// any voice is authored as <durationType>measure</…>, not
// <durationType>whole</…>. With NoteDuration.measure present
// in the model, this distinction is honoured.
let isMeasureRest: Bool = {
    if case .measure = r.duration { return true }
    return false
}()
let restX: CGFloat
if isMeasureRest {
    let trailingPad = metrics.sp * 1
    restX = (
        headerSchedule.contentStartX
            + width - trailingPad,
    ) / 2
} else {
    restX = timedX(atTick: tickCursor)
}
```

`restBase` (from `DurationInterpretation.split(r.duration)`) is
still used for the `restY` switch and the leger-line predicate;
nothing else moves.

### `restY` — unchanged

Whole-glyph rests (resolved via `restBase == .whole`) still hang
from staff line 4. Half-glyph rests sit on the middle line.
Others centre on the middle line. Voice 2/3/4 still get
`restVoiceOffset` to avoid the melody's vertical band.

### Leger-line predicate — unchanged

A whole / half rest pushed off the staff by `restVoiceOffset` still
gets `restWholeLegerLine` / `restHalfLegerLine`. Unaffected.

### Tests

- **New** `Tests/SheetMusicTests/TypedRestPositioningTests.swift`:
  - In a 6/4 bar containing `[.rest(duration: .whole),
    .rest(duration: .half)]`, assert the whole rest's X equals
    `timedX(atTick: 0)` and the half rest's X equals
    `timedX(atTick: 4 * division)`. Equivalently: `wholeX <
    halfX` with the half landing strictly after.
  - Add a paired control: in the same 6/4 bar, a single
    `[.rest(duration: .measure)]` centres in the chord area
    (asserts `measureX > timedX(atTick: 0)` and `measureX <
    barWidth - trailingPad`).

- **Migrate** the `Voice-1 whole rest centers in the measure`
  fixture in
  `Tests/SheetMusicTests/MultiStaffAlignmentTests.swift:186`:
  change `.rest(duration: .whole)` to `.rest(duration: .measure)`.
  The test's assertion (rest X is centred, distinct from voice 0's
  tick-0 X) remains correct — only the spelling changes.

- **Inventory other layout tests** that author `.rest(duration:
  .whole)` and rely on centring. Grep:
  `grep -rn '\.rest(duration: \.whole)' Tests/`. For each hit,
  decide:
  - The author intended "a measure-filling rest" (typical for
    multi-voice scenarios) → migrate to `.measure`.
  - The author intended a typed whole rest at its start beat
    → leave as `.whole`, update any centring assertion that
    will now fail.

## Compatibility

### Breaking-change scope

Behavioural change for any caller / fixture that:

- Authored a `.rest(duration: .whole)` and expected centring.

Test fixtures: the inventory above covers known cases.

External consumers: none in this repo. The example apps
(`SheetMusicExample`, `SheetMusicExampleMac`) build against the
package; if they author whole rests, the visual will change.

### MSCX round-trip

Unaffected. The MSCX decoder already distinguishes
`<durationType>measure</…>` (→ `.measure`) from
`<durationType>whole</…>` (→ `.whole`). Round-trip preserves the
distinction.

### MIDI

Unaffected. `chord.duration.resolved(in: …).ticks(...)` is the
same for `.whole` (4 × division) regardless of where the rest is
positioned visually.

## Open questions

None.

## Out-of-scope follow-ups

None today. The "centre any rest that visually fills the bar"
heuristic is fully retired by this change; MuseScore's data-model
distinction (`.measure` vs typed) is now the single source of
truth.
