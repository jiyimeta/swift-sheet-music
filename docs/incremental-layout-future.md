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

Source paths are relative to the upstream MuseScore repository root
(<https://github.com/musescore/MuseScore>, GPL-3.0; not vendored — clone
separately for reference).

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
  layout engine renormalizes within each system).

Even with those skipped, the relayout itself remains `O(measures)`,
hence the residual lag.

## 案1 — per-measure cache (shipped on `feature/incremental-layout`)

`LayoutEngine.layout(score:, options:, availableWidth:, cache:
LayoutCache)` overload memoizes per-measure work:

* `crossStaffMinimumMeasureWidth` keyed by `(measureIdx, [Measure?]
  per staff, sp, division)`.
* `placeMeasureElements` keyed per-`(measure, staff)` by all of its
  inputs (`Measure`, `width`, `metricsSp`, `activeClef`, `activeKey`,
  `headerSchedule`, `tickColumns`, `drumLineMap`, `isLastMeasure`,
  `incomingMelismas`, `effectiveMelismaTicks`).

Cache is rebuilt in place each call: prior entries are copied
forward only on input match.

### Per-system extension

Per-measure caching alone left ~75 % of layout time on the table —
score-wide passes plus the `buildSystem` post-placement work
(system-wide lyric-Y align, per-staff Y-bound skyline, translate,
`buildEventColumns`).

Promoting the cache to **per-system** granularity recovers the
rest. `LayoutCache.SystemEntry` captures all `buildSystem` inputs
(`measureRange`, stretched widths, `isFirstSystem`, carry-in
clef/key, sliced melisma data, drum maps, `ScoreViewOptions`, all
staves' `Measure` values for the range) and stores the produced
`LayoutSystem` normalized to `origin.y == 0`. On a hit the entire
`buildSystem` call is skipped; the cached system is shifted to the
current packing Y and the carry-out clef/key restored.

This mirrors MuseScore's `rangeDone` early exit
(`engraving/rendering/score/systemlayout.cpp:318`) at finer
granularity — a single-note edit invalidates one system, the rest
are reused intact.

### Bench (`Examples/Apple/SheetMusicExample/test.mscx`, 112 measures × 6 staves)

Release config, `swift test -c release`:

```
cold (no cache):       98.4 ms
cold (populate cache): 93.2 ms
warm (all cached):      3.8 ms       — 96 % faster, full system hits
edit (1 measure):       4.9 ms       — 1 system miss, 0 system hits
                                        (single-system score), 18
                                        placement hits + 6 misses
                                        inside the missed system
```

The remaining ~5 ms in the warm/edit path is dominated by the
score-wide post-passes (`collectSpanners`/`attachSpanners`,
`resolveTies`/`attachTies`) and the score-wide melisma precompute,
all of which still run unconditionally.

### Correction (2026-07-28) — the 112-measure fixture hid an O(measures²) term

The "3-5 ms is below user-perceivable lag" conclusion above does
**not** hold at scale, and the note-input-perf investigation
(`.superpowers/sdd/2026-07-28-note-input-perf/`) found why:
`aggregatedTickWeights` re-derived one measure's effective duration
by walking the *whole* staff's measure list on every call, so its
cost scaled with the square of the score's measure count. At 112
measures that term is invisible next to everything else; on a
synthetic 1300-measure × 6-staff score it was **~97 % of a one-note
edit's layout time** before the fix.

That 97 % comes from a pass-by-pass profile taken with a temporary
`Date()`-based trace probe compiled into the pass-1 inner loop. The
probe's own overhead inflates every absolute millisecond it reports,
so those numbers are deliberately not quoted here: the **ratio** is
the finding, not the milliseconds. The absolute before/after figures
in the table below come from clean, unprobed runs instead.

A second, structural factor compounds the first: horizontal mode
(`ScoreViewOptions(wrapToViewWidth: false)`) packs the *entire*
score into **one** `LayoutSystem`. That makes the per-system cache
above inert by construction — every edit is a full-system miss — so
the per-measure passes (`aggregatedTickWeights` among them) dominate
horizontal-mode timings even after the per-system cache landed.
Vertical mode (158 systems on the same score) looked fine because
only the one edited system misses the per-system cache; the other
157 are served from it.

#### Measurements

Conditions, once, for every number below: Release config
(`swift test -c release`), the `NoteInputPipelineBenchmark` suite
(`.serialized`), one machine, nothing else running, the two runs taken
sequentially — never concurrently. The score is the synthetic
1300-measure × 6-staff corpus built by
`Tests/SheetMusicTests/NoteInputPipelineBenchmark.swift`; horizontal
mode packs it into 1 `LayoutSystem`, vertical mode into 158.

BEFORE is the merge base (`a3fa6600`), with the benchmark file copied
back onto it and minimally adapted to the pre-change APIs. AFTER is
this branch's tip.

```
                                            BEFORE      AFTER
                                          (a3fa6600)  (branch tip)
LayoutEngine.layout
  horizontal, cold                          335.0 ms     38.5 ms
  horizontal, warm (all cache hits)           8.8 ms      6.8 ms
  horizontal, 1-measure edit                 167.6 ms     22.1 ms
    of which packSystems                     157.9 ms     21.3 ms
  vertical, cold                             427.4 ms     35.8 ms
  vertical, 1-measure edit                    10.3 ms      7.2 ms

CALayer build
  buildSystemWithItems (whole horizontal
    score, 1 system of 1300 measures)         48.1 ms     37.1 ms
  rebuild ALL 158 vertical systems' layers     45.1 ms     46.1 ms
  rebuild ONE vertical system's layers          0.3 ms      0.4 ms
```

Phase 1 (Tasks 1-4: the `aggregatedTickWeights` fix plus the
per-measure / per-system caches above) is what the `LayoutEngine
.layout` rows measure — a 7.6× cut on a horizontal one-measure edit
and ~9-12× on the cold paths.

Phase 2 (Tasks 5-8) does **not** show up in the CALayer-build rows,
and that is expected rather than disappointing: it did not make
`buildSystemWithItems` faster (48.1 → 37.1 ms is a modest change, and
rebuilding all 158 vertical systems is flat at ~45 ms across both
sides). What Phase 2 changed is that an edit no longer *calls*
`buildSystemWithItems` at all. `MeasureLayerDiffPlanner`
(`Sources/SheetMusicUI/Rendering/MeasureLayerDiffPlanner.swift`) is a
pure function of the previous and new `LayoutSystem` that decides,
per measure, whether to reposition an unchanged container or rebuild
it; `SystemLayerView+MeasureDiff.swift` applies that plan by
rebuilding only the flagged `CALayer` subtrees via
`ScoreLayerBuilder.buildMeasure`. That path exists only on the AFTER
side, so it has no BEFORE counterpart to compare against — the
honest comparison is against the full rebuild it replaces, on the
same run:

```
AFTER only (no BEFORE counterpart — the API did not exist)
MeasureLayerDiffPlanner.plan                      1.3 ms
rebuild only measures the plan flags              0.2 ms  (1 of 1300)
                                                  ------
                                                   1.5 ms
  vs. 37.1 ms to rebuild the whole horizontal system
```

Vertical mode already got the equivalent scoping for free from the
per-system cache: a one-note edit dirties 1 `LayoutSystem` out of
158, and rebuilding that one system's layers costs 0.4 ms against
46.1 ms for all 158. Horizontal mode has no such luxury — the whole
score is one system — which is exactly why the per-measure diff
matters there specifically.

Conclusion for future work: engine-level layout cost (the
`LayoutEngine.layout` rows above) is now small enough that it is
very unlikely to be the bottleneck in an interactive editor. The
place worth watching next is the `CALayer` build/apply path measured
here, and the end-to-end pipeline captured by
`example(macOS): instrument edit pipeline timing`, which is the only
place rendering / scroll-view overhead is visible.

The benchmarks live in
`Tests/SheetMusicTests/LayoutCacheBenchmark.swift` (the 112-measure
fixture above) and `Tests/SheetMusicTests/NoteInputPipelineBenchmark.swift`
(the 1300-measure × 6-staff corpus used for this correction),
both gated by `SHEETMUSIC_RUN_LAYOUT_BENCH=1`.

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
* `src/engraving/rendering/score/systemlayout.cpp:318` —
  the canonical "stable boundary" predicate to mirror.

## Out of scope for this doc

* Whether to add per-measure dirty flags as well (MuseScore doesn't,
  and the tick-range approach is simpler for a port).
* Background-thread layout. The MuseScore approach makes layout
  cheap enough on the main thread; deferring it loses synchronous
  edit feedback. Consider only if the incremental refactor still
  isn't fast enough.
