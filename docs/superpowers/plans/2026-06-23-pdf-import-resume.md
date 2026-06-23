# PDF Import — Resume / Productionization Plan

Date: 2026-06-23
Branch: `spike/pdf-import-cmap` (all work uncommitted at time of writing)
Supersedes the "paused" status in
`docs/superpowers/plans/2026-05-03-pdf-import-paused.md`.
Design reference: `docs/superpowers/specs/2026-05-03-pdf-import-design.md`.

## TL;DR

The year-old blocker that paused PDF import — the **CID→Unicode CMap
wall** — is **solved**. The importer was then driven to near-complete
musical-content parity against a **real MuseScore export** used as
ground truth: `~/Desktop/ギブス.mscz` (MuseScore 3.6.2, 5-part vocal
arrangement, 91 measures) and its own PDF export `~/Desktop/ギブス.pdf`
(9 pages, Leland/Edwin SMuFL fonts, CID TrueType / Identity-H).

Convergence of `Score(pdf)` against `Score(mscz)` (every figure below was
produced by an independent adversarial verifier re-running the harness,
not self-reported):

| Dimension | Result |
|---|---|
| Parts / Staves / Measures | **5 / 5 / 91 — EXACT** |
| Notes / Rests / Chords | **1608 / 316 / 1608 — EXACT** |
| Grace notes (count + per-part) | **13, [3,5,0,5,0] — EXACT** |
| Clef / Key / Time signature | **100% / 100% / 100%** (455/455 each) |
| Pitch (by value) | **100%** (1608/1608) |
| Duration (by value) | **100%** (1608/1608) |
| Ties | recall **89%**, precision **100%** |
| Title / Subtitle | **EXACT** (ギブス / 椎名林檎) |
| Composer | text exact, inter-word spaces lost |
| Lyrics | precision 92%, recall 33% (271 vs 750) |

This validates the spec's core thesis — *structural extraction from
MuseScore vector PDFs is viable* — on a real, dense, multi-part score,
not just a synthetic round-trip.

> **Update (rhythm re-architecture).** Pitch and duration above started
> at 99% / 94%. A follow-up re-architecture (see below) took **both to
> 100%** by treating beams as sloped polygons with group-membership
> inference + a metric-sum reconciliation, and by propagating tie-carried
> accidentals. Crucially this **disproved an earlier "fundamental
> information loss" claim** for duration: every duration error was
> *captured-but-mis-associated* geometry, not absent information — see the
> corrected section below.

## What "完全一致" can and cannot reach (proven, not assumed)

The remaining gap was classified by raw content-stream probing
(independent `CGPDFScanner` dumps), not guessed:

### Correction — duration was NOT information loss (earlier claim was wrong)
An earlier draft of this plan labelled ~50–55 duration notes as
"fundamental PDF-information-loss" (beams allegedly not drawn over interior
stems). **A forensic re-probe disproved this.** Census over all 9 pages:
356 filled beam quads captured, **zero dropped**; flags present; every
duration error was a *value error on an existing slot*. The errors were
**captured-but-mis-associated geometry**:
- beams were collapsed to an axis-aligned bbox (a sloped beam inflated it,
  so the per-stem y-gate fished a ~13pt window an interior/short stem
  couldn't reach) → `8→q`;
- vertically-aligned neighbouring staves let a same-x beam/flag be grabbed
  by the wrong stem → `8→16`, `q→16`, `q→8`;
- fractional (partial) beams had no ownership model → dotted-family
  confusion.
Plus two independent backstops a human uses: **17/17 failing bars violated
the 4/4 measure sum**, and **x-position is monotonic in duration**.

The re-architecture (geometry group-membership + metric-sum reconciliation
+ tie-pitch propagation) recovered **all of it**: duration **94% → 100%
(1608/1608)** and pitch **99% → 100% (1608/1608)**, both proven monotonic
(no previously-correct note regressed).

### Still recoverable, not yet done (info is on the page)
- **Tie recall 89% → higher** — 48 of A's ties undetected (precision is
  already 100%, no false ties). The tie *arcs* are drawn; needs
  short/sloped-arc detection. By the same logic as duration, this is
  mis-/under-detection, not absence.
- **Lyric recall 33% → higher** — capture is solved (92% precision); a
  smarter per-cell gate + melisma / hyphen-continuation handling lifts
  recall.

### Genuinely absent from the PDF (irreducible)
- **Composer inter-word spaces.** MuseScore emits no space glyph, and the
  word-boundary x-step (~8pt) is indistinguishable from intra-word
  advances. "Arranged by Kiichi" recovers as "ArrangedbyKiichi". This is
  the *only* confirmed genuine information loss found.

### Out of scope by design (present in the mscz, never in scope for v1)
Dynamics, slurs, articulations, ornaments, hairpins, pedal, MIDI
velocities / channels / instrument sound IDs, and layout coordinates.
These exist in `Score(mscz)` but the importer does not (and the spec
says will not) reconstruct them, so a *full Score model* comparison will
always differ on these. The convergence above is **musical content**,
which is the meaningful target for a re-import use case.

**Bottom line:** on this ground truth, **pitch, duration, and all
structure (parts/staves/measures/notes/rests/grace/clef/key/time) reach
100%.** The only non-exact compared dimensions are tie *recall* (89%) and
lyric *recall* (33%) — both recoverable (the geometry is on the page) and
not yet done — plus deliberately out-of-scope fields. The single confirmed
*irreducible* loss is composer word-spaces (no space glyph). "完全一致" on
musical content is therefore achievable; only out-of-scope fields
(dynamics/slurs/MIDI/layout) keep a *full Score-model* comparison from
being byte-identical.

## What was implemented (on `spike/pdf-import-cmap`, uncommitted)

The work also confirms the paused doc's resume-checklist item 1: the
importer **already compiles against current `SheetMusicCore.Score`** — it
did not bit-rot during the intervening refactors.

New files under `Sources/SheetMusicPDF/Import/`:
- `PDFImporter+ToUnicodeCMap.swift` — real `/ToUnicode` CMap parser
  (handles `bfchar`, both `bfrange` shapes incl. the array form,
  multi-scalar UTF-16BE destinations). **The make-or-break fix.**
- `PDFImporter+Systems.swift` — bracket-spine system clustering
  (assign staves to the tall left-bracket spine that contains them).
- `PDFImporter+Beams.swift` — beam-level counting per stem + a capped,
  strict-interior primary-beam rescue.
- `PDFImporter+Ties.swift` — tie-arc (filled Bézier lens) detection +
  same-pitch endpoint pairing → tieForward / tieBack.
- `PDFImporter+Graces.swift` — grace-notehead detection by rendered
  size + attachment as `GraceChord` on `Chord.graceNotesBefore`.
- `PDFImporter+ContentStream+TextShow.swift` — extracted emit helpers
  (file-length cap).

Rhythm re-architecture (the 99/94 → 100/100 follow-up):
- `PDFImporter+BeamGroups.swift` + `PDFImporter+UnionFind.swift` — sloped
  `BeamQuad` capture, point-in-band membership at each stem's x, union-find
  beam groups with interior-inheritance (a grouped stem is ≥ eighth), and
  partial-beam stub levels. Replaced the per-stem bbox `beamLevelCount` /
  `primaryBeamRescueLevel`. Flag matching is now staff-y-band-scoped.
- `PDFImporter+RhythmReconcile.swift` — metric backstop: per voice/measure,
  if the note+rest durations don't sum to the bar length, repair exactly
  one low-confidence note (x-onset least-squares as the tie-break); a
  provable **no-op on metrically-valid measures** (never regresses).
- `PDFImporter+TiePitch.swift` — a tied-back note adopts its tie source's
  pitch/tpc (MuseScore omits the carried accidental on the continuation
  note). Fixed the lone pitch residual.

Modified (14 files): the content-stream walker now extracts per-font
CMaps and routes SMuFL-PUA scalars to `RawGlyph` (CID→PUA→RawGlyph);
staff-line detection (line-merge tolerance, stroke-width barline gate,
glyph-detected xRange inheriting content width); layout (spine
clustering, exactly-2-staff brace coupling, phantom-cell coalescing);
pitch (positional accidentals, G8vb clef anchor); rhythm (notehead-
anchored flag y-gate — the dominant duration lever, tightened dot
window); lyrics (syllable run-grouping + x-cell-gated attachment);
title/composer (text-run merging). Net **+1172 / −365** plus the 6 new
files.

Also: 3 **unrelated** bit-rot test fixes
(`DynamicSymbolMapTests`, `AndroidJNI/CursorBridgeTests`,
`AndroidJNI/LayoutBridgeBracketsTests`) were needed only to make the
shared test target compile (pre-existing main-branch API drift,
unrelated to PDF). `swiftlint` on the changed `Import/` files is clean;
all 86 existing `PDFImporter*` unit tests pass.

**Not committable as-is:** `Tests/SheetMusicTests/PDFGibbsGroundTruthSpikeTests.swift`
reads the copyrighted `~/Desktop/ギブス.{mscz,pdf}`. It is the
measurement harness, not a shippable test, and must be removed or
replaced before any commit lands on a shared branch.

## Productionization tasks (the actual resume work)

The spike proves **feasibility on one score**. Generalization is the
real remaining engineering. In priority order:

1. **Generalize the per-PDF heuristics.** Every threshold was tuned to
   this one print size: barline stroke-width gate (1.3× staff-line
   width), 2-staff brace coupling, grace size threshold (0.85× median
   notehead), flag y-gate offsets (±[4,22]pt), beam-overlap tolerances,
   lyric x-gap split (fontSize×0.32), dot window (12pt), bracket-spine
   clustering. Parameterize against spatium / staff size and validate
   across several MuseScore exports of different sizes and fonts.

2. **Validate on genuinely multi-voice / dense scores.** Gibbs is
   `multiVoice=0`. The voicing pass, the beam-group "cannot inflate"
   rescue (only provably safe for single-voice), and measure assembly
   need testing on polyphonic scores (piano grand staff, SATB divisi,
   voice 1/2 interleaving).

3. **Confirm a true MuseScore 4 native export.** Gibbs is 3.6.2
   (Leland/Edwin, which 3.6 already shipped). Run the same ground-truth
   comparison against an MS4-authored PDF.

4. **Replace the spike harness with shippable tests.** Tighten the
   existing self-roundtrip golden (MSCX → `PDFExporter` →
   `PDFImporter`) with the new duration / tie / grace / lyric
   comparators, and add a redistributable real-export fixture
   (public-domain or self-authored score). Keep GPL/copyright
   discipline — no `~/Desktop` reads, no committed copyrighted PDFs.

5. **Re-expose the public API** (paused-doc resume checklist 4):
   `public PDFImporter` / `PDFImportOptions`; `SheetMusic.loadScore(pdfURL:)`
   / `(pdfData:)`; restore `SheetMusicPDF` in the `SheetMusic` umbrella
   target deps in `Package.swift`; example app `.pdf` open path +
   `Info.plist`. Have `PDFImportDiagnostic` surface the
   genuinely-unrecoverable cases (bare-stem rhythm, lost spaces).

6. **Document the recovery contract.** State plainly what PDF import
   guarantees (structure / pitch / clef / key / time ≈ exact),
   best-effort (duration ~94%, ties, lyrics), and never (dynamics,
   slurs, MIDI velocities, layout). Sets honest caller expectations.

7. **(Separate, optional) Reference-parser grace-note gap.** `MSCZReader`
   drops the 13 `<acciaccatura>` grace notes from the main note stream
   (A main-count 1608 vs raw 1621). Not a PDF problem; a `SheetMusicMSCX`
   fix in its own right.

8. **(Stretch) Squeeze the fixable residual:** beam-group segmentation
   (duration → ~97%), tie recall, lyric recall.

## Risks & open decisions

- **#1 risk: heuristic brittleness across PDFs.** The spike is one data
  point. Tasks 1–3 are where the feature earns production trust.
- **Decision: how to preserve/integrate the spike work** — commit the
  branch (preserve 7 rounds of verified work), or keep as reference and
  re-implement against tests. The harness must be excised from any
  commit (copyright).
- **Decision: target scope** — accept musical-content parity (current
  result) as the v1 bar, or invest in the fixable-but-risky levers
  (task 8) before re-exposing the API.
