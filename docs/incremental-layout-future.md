# Incremental Layout — Future Work

## Status

`SheetMusicLayout.LayoutEngine.layout(score:options:availableWidth:)`
recomputes the **entire** score's layout on every call. For the
note-input pipeline added on `feature/note-input-mode`, this means
every keystroke triggers a full re-layout: ~0.5–1 s on the bundled
`test.mscx` (1356 measures). MuseScore handles the same score size
with no perceptible lag.

This document records the architectural difference, so a future plan
(e.g. `docs/superpowers/plans/YYYY-MM-DD-incremental-layout.md`) has
a starting point.

## How MuseScore avoids full re-layout

Source paths refer to the upstream MuseScore git submodule
(`MuseScore/`, dev-only, GPL-3.0).

1. **Tick-bounded dirty range** —
   `engraving/editing/cmd.cpp` `CmdState::setTick(Fraction)` records
   the start/end tick affected by the current command. Each note-
   input edit calls it for the modified measure's tick range; this
   automatically sets `UpdateMode::Layout`.

2. **Range-bounded entry point** —
   `engraving/dom/score.cpp:5953` `Score::doLayoutRange(startTick,
   endTick)` is the actual relayout call. It only walks measures in
   the requested range; downstream measures are visited only if the
   layout pass discovers a need to.

3. **Early-exit on system collection** —
   `engraving/rendering/score/systemlayout.cpp:290–368`
   `SystemLayout::collectSystem` collects measures from `startTick`
   forward. At each measure boundary it checks (`line 318`) whether
   `endTick < prevMeasure->tick()` AND no cross-measure beam spans
   the boundary, and if so sets `LayoutState::m_rangeDone = true`.

4. **Stop loop when stable** —
   `engraving/rendering/score/scorepageviewlayout.cpp:198–228`
   `ScorePageViewLayout::doLayout` exits its outer system/page loop
   when `rangeDone && lastMeasure == pageOldMeasure()`. I.e. if the
   last measure laid out matches the previous layout pass's last
   measure for that page, downstream pages are skipped entirely.

There are **no per-measure dirty flags**. The mechanism is purely
"layout from this tick onward, stop as soon as nothing changes
downstream." Cross-measure spanners (beams, ties, slurs) determine
whether the boundary is stable.

## What this implies for `SheetMusicLayout`

The current `LayoutEngine` is "all or nothing":

* `LayoutEngine.layout(score:, options:, availableWidth:)` builds a
  fresh `LayoutDocument` from scratch. There is no entry point that
  takes a previous `LayoutDocument` and a tick range to skip.
* `LayoutSystem` is a value type whose contents are derived
  end-to-end during the single layout pass; nothing is reusable
  across passes.
* `LayoutEngine.naturalContentWidth(score:, options:)` walks every
  measure to compute total width — `O(measures)` even for a
  single-note edit.

To match MuseScore's responsiveness, the engine needs:

1. **An incremental entry point.** Something like
   `LayoutEngine.layoutRange(score:, options:, previous:
   LayoutDocument, dirtyTickRange: ClosedRange<Int>) ->
   LayoutDocument` that returns a new document with measures /
   systems outside the dirty range copied from `previous`.
2. **Cross-measure dependency tracking.** `LayoutSystem` (or a
   sibling structure) needs to know which measures cross boundaries
   via beam / tie / slur. The early-exit predicate is "no spanner
   crosses this boundary AND the measure's width is unchanged from
   `previous`."
3. **Per-measure stable artifacts.** Width / height / glyph
   positions per measure must be cheaply queryable on `previous`,
   so the rangeDone check (compare new computed measure vs
   previous) is `O(1)`.

This is a sizeable piece of work — MuseScore's incremental layout
machinery spans `engraving/rendering/score/{systemlayout,
scorepageviewlayout, layoutcontext}.{h,cpp}` and ~2000 lines of
support code. Plan as its own multi-task project.

## What we're shipping today instead

The note-input slice on `feature/note-input-mode` triggers a full
synchronous relayout per edit, but skips two redundant walks:

* `LayoutEngine.measureContexts(for:)` — per-measure clef / key /
  time / part metadata. A note-pitch edit cannot affect this, so
  the host (`ContentViewMac.adoptEditedScore`) reuses the existing
  `horizontalContexts`.
* `LayoutEngine.naturalContentWidth(score:, options:)` — full-score
  width walk. The host reuses `horizontalDoc.size.width` from the
  previous layout (drift on note-vs-rest swap is sub-glyph; the
  layout engine renormalises within each system).

Even with those skipped, the relayout itself remains `O(measures)`,
hence the residual lag.

## Pointers when the time comes

* `Sources/SheetMusicLayout/Layout/LayoutEngine.swift` — `layout(...)`,
  `naturalContentWidth(...)`, `measureContexts(...)`. Entry points.
* `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift` —
  width / X-position derivation per system; lines 102, 173, 222 are
  the ones to study when introducing a "previous-system width
  reuse" path.
* `Sources/SheetMusicLayout/Layout/LayoutSystem.swift` — value-typed
  system; doesn't currently expose per-measure boundary information.
  An incremental refactor will likely add a `measureSpans:
  [MeasureSpan]` field where `MeasureSpan` carries (startTick,
  endTick, width, hasCrossMeasureSpanner).
* `MuseScore/src/engraving/rendering/score/systemlayout.cpp:318` —
  the canonical "stable boundary" predicate to mirror.

## Out of scope for this doc

* Whether to add per-measure dirty flags as well (MuseScore doesn't,
  and the tick-range approach is simpler for a port).
* Background-thread layout. The MuseScore approach makes layout
  cheap enough on the main thread; deferring it loses synchronous
  edit feedback. Consider only if the incremental refactor still
  isn't fast enough.
