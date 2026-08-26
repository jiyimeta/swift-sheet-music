# Training — synthetic OMR dataset generation (P3c)

Scripts that generate the synthetic training/eval datasets for the raster
OMR program (see docs/superpowers/specs/2026-08-06-omr-raster-foundation-design.md).
Datasets live OUTSIDE the repo at `~/Datasets/sheet-music-omr/<version>/`
(override with `OMR_DATA_ROOT`). Nothing dataset-sized or copyrighted is
ever committed; admissible sources are procedurally generated scores,
public-domain scores, and the repository owner's own originals only.

## Setup

    python3.13 -m venv Training/.venv
    Training/.venv/bin/pip install -r Training/requirements.txt

**Use Python 3.13, not whatever `python3` resolves to on a Homebrew host**
(often the newest installed minor, 3.14 as of this writing). `coremltools`
9.0 publishes compiled wheels only up to `cp313`; pip silently falls back
to a `py3-none-any` sdist build on 3.14 that is missing its native
extensions (`_MLModelProxy`, `libmilstoragepython`'s `BlobWriter`/
`BlobReader`), so `ct.convert(..., convert_to="mlprogram")` fails with
`RuntimeError: BlobWriter not loaded` and `ct.models.MLModel(...)` can't
load anything — with no import-time error to point at the cause. Verify
after install with `Training/.venv/bin/python -c "import coremltools;
import coremltools.libcoremlpython"` — a clean import (mentioning nothing
about a missing module) means the real extension loaded.

## Tests

    Training/.venv/bin/pytest Training/tests -q

## Export (`model/export.py`)

Packages a `checkpoint.pt` from `model.train` into the three artifacts the
Swift side consumes: `model.mlpackage` (Apple inference), `model.onnx`
(canonical, for the later Android conversion — nothing in Swift uses it
this round), and `model.json` (the manifest `OMRDetectorFrontEnd` checks
the frozen class vocabulary against before loading anything).

    Training/.venv/bin/python -m model.export \
        --checkpoint ~/omr-models/run1/checkpoint.pt --out ~/omr-models/run1 \
        --tile 384 --staff-space-px 12.0 --overlap 64

`--checkpoint random` exports a freshly initialized, untrained network with
no checkpoint file needed — the P3d-G1 floor a trained model is measured
against, produced before training so the floor is not chosen after seeing
a result.

**Conversion path: `torch.jit.trace` + `ct.convert`, as the plan's Step 3
specifies — `coremltools` did not reject it, so the `torch.export` +
`ExportedProgram` fallback was not needed to get a working `.mlpackage`.**
It was tried anyway, to see whether it would clear `torch.jit.trace`'s own
deprecation notice under torch 2.13 (which nudges callers toward
`torch.compile`/`torch.export`): `torch.export.export(...).run_decompositions({})`
followed by `ct.convert` on the resulting `ExportedProgram` does convert
successfully, but trades one clean, well-understood warning for roughly 50
repeated internal `coremltools` `_TORCH_OPS_REGISTRY.__contains__`
deprecation warnings, plus a `FutureWarning` from `torch.export`'s own
pytree handling and a `ResourceWarning` from an implicitly-cleaned-up temp
directory — strictly worse under the versions pinned in
`requirements.txt`. `export.py` keeps `torch.jit.trace` and silences its
own notice deliberately (`_silence_known_export_deprecations`), rather
than switching graph-capture strategy to chase a warning that trades down.

## MuseScore CLI export (`generate/export_pdf.py`)

Renders a generated `.mscx`/`.mscz` source to PDF via the MuseScore CLI,
under process supervision that encodes measured (not assumed) MuseScore
behavior: MuseScore 4's PDF export can write a complete file and then
never exit, and its crash reporter can make a successful export exit
non-zero. Success is judged only by output-file completeness (trailing
`%%EOF` + a readable page count); exit codes and timeouts are recorded
but never trusted. One retry; a still-incomplete output after the retry
is the caller's cue to quarantine the source.

Engine binary locations are environment-overridable rather than
hard-coded, since MuseScore.app's install path is host-specific:

    OMR_MSCORE4_BIN   default: /Applications/MuseScore 4.app/Contents/MacOS/mscore
    OMR_MSCORE3_BIN   default: /Applications/MuseScore 3.app/Contents/MacOS/mscore

Note MuseScore 3 refuses to open a score written by a newer MuseScore,
so an MS3-schema source is required for the MS3 arm to do anything at
all; and MS3's macOS build has no `offscreen` QPA platform (`cocoa` is
the only one available), unlike MS4.

## Orchestrator (`generate/build_dataset.py`)

One deterministic entry point: a single dataset seed drives the
generators, the style matrix, and every rasterization dpi. Run it either
way — both forms work with no `PYTHONPATH`:

    python Training/generate/build_dataset.py <cmd> ...   # from the repo root
    python -m generate.build_dataset <cmd> ...            # from Training/

Everything below uses the first form, so one working directory (the repo
root) serves the whole runbook — `swift test` has to run there anyway.
Substitute `Training/.venv/bin/python` for `python`.

| Subcommand | Arguments | Does |
|---|---|---|
| `generate` | `--root --seed [--engines ms4] [--per-face 1] [--textures 20] [--extra-sources DIR...] [--probe-faces ENGINE=Face,Face] [--pin-page] [--allow-existing] [--resume]` | Phase 1: sources → styled score → PDF → raster |
| `finalize` | `--root --seed [--class-floor 1000]` | Phase 3: writes `manifest.json`, scores P3c-G2 / P3c-G3 |
| `status` | `--root` | Which phase the dataset is in, and the exact next command |
| `faces` | `--root [--tol 0.01]` | Gate P3c-G4 |
| `freeze` | `--root --seed [--profile PATH]` | Frozen eval set (spec §6.5) |
| `coco` | `--root [--out PATH]` | Convenience COCO detection export |
| `compare` | `ROOT_A ROOT_B` | Gate P3c-G1 |

Exit code 1 means a gate failed, and only `compare` and `faces` use it.
`finalize` always exits 0 (it wrote the manifest); read its
`[gate][SUMMARY]` lines for the P3c-G2 / P3c-G3 verdicts.

### The phase boundary

Label export lives in the Swift test target, so Python cannot call it.
The pipeline is therefore two Python phases with a Swift step between:

    1. build_dataset.py generate ...      (Python)
    2. OMR_LABEL_EXPORT=1 swift test      (Swift)
    3. build_dataset.py finalize ...      (Python)

Between 1 and 3 the dataset is **generated but unlabeled**: each render
directory holds `source.mscx` (or `source.mscz`), `score.pdf`,
`page_<n>.png` and `render.json`, and no `page_<n>.labels.json`. The
root also holds `quarantine.json` and `dataset_plan.json`. That is a
legal resting state — `status` names it, and every Swift harness skips a
render directory that has no labels rather than failing. Run
`build_dataset.py status --root R` at any point to see which phase you
are in and what to run next.

An interrupted `generate` can be continued with `--resume`, which skips
every plan entry whose render directory already holds a `render.json`
and prints `resumed=N` next to `exported=`. It is sound because the plan
is a pure function of the seed, so the entry being skipped is the entry
the interrupted run executed — pass the **same arguments**, above all
the same `--seed`, or the plan is a different plan. A directory holding
labels is never skipped: that is the stale-label hazard below wearing a
different hat, so such a render is regenerated instead.

`dataset_plan.json` is written **before the first export**, so an
interrupted run still records what it set out to do. Two later gates
depend on it, and both would otherwise be silently wrong after an
interrupted `generate`: P3c-G2's denominator (a render that never
happened is neither exported nor quarantined, so counting only what
survived on disk scores an aborted run as a perfect 100%), and P3c-G4's
expected face set (a face whose every render was quarantined leaves no
directory behind — see below). If the file is absent, both fall back to
what is on disk and say so: `denominator=disk` on the P3c-G2 line.

A directory is a render only once it owns a `render.json`, and
`render.json` is written **last** — after a successful export and a
successful rasterization. A render that failed anywhere is therefore
invisible to the manifest, to `coco`, and to every Swift harness, rather
than half-consumed. `freeze` writes `frozen.json` instead (also last),
for the same reason and with one extra: naming its marker differently is
what keeps a second `freeze` from re-degrading its own output. `coco`
recognizes both markers; nothing else recognizes `frozen.json`. For the same reason, `generate` refuses to write
into a root that already holds renders (`--allow-existing` overrides):
regenerating over one would leave the previous run's `*.labels.json` in
place for `finalize` to hash as if this run had produced them.

### Measure-length validation (`generate/validate_mscx.py`)

Before the first export, `generate` sums every voice of every measure
of every source **this repo generated** and compares it against the
meter in force. A mismatch aborts the run with
`[generate][FATAL] … bad measure(s) …`, naming each bar and both sums.
`--extra-sources` scores are exempt: those are the owner's own files,
so a defect in one is data to quarantine downstream, not a bug here.

This is not a stylistic check. Both failure directions were measured on
the first real pilot run:

- **Overfull** — MuseScore 4 aborts during layout (`libc++abi: … mutex
  lock failed: Invalid argument`) and writes no PDF, so the source is
  lost in *every* face at once. `cov_durations` shipped a 4/4 bar
  holding 6 quarters and took all 8 of its faces down with it.
- **Underfull** — MuseScore pads the bar **silently**. The render looks
  right, the labels describe what was drawn, and the ground truth
  parsed back out of `source.mscx` describes something shorter, with
  nothing anywhere reporting it. `cov_timesigs` filled its 7/8 and 9/8
  bars with quarter notes.

Grace chords are not charged to the bar, tuplet members are scaled by
`normalNotes/actualNotes`, and a `<Measure len="a/b">` attribute
overrides the meter — all three mirroring this repo's own
`MSCXDecoder+Voice.swift` rather than a reading of the schema.

`generate` never rasterizes a PDF that failed its completeness check.
`export_pdf` judges success only by `ExportOutcome.ok` (MuseScore can
leave a torn PDF on disk, and a successful export can exit non-zero or
hang), and `rasterize_pdf` deliberately does not re-check — so the
orchestrator's gate is the only one there is.

## Pilot dataset runbook (gates P0-G1..G4, P3c-G1..G4)

Requires MuseScore 4 (and MuseScore 3 for the MS3 arm); override the
binaries with `OMR_MSCORE4_BIN` / `OMR_MSCORE3_BIN`. All commands run
from the repo root. Steps needing MuseScore or the owner's own scores
are marked; on a bare checkout everything else still runs, and
`Training/.venv/bin/pytest Training/tests` must be green regardless.

Pick a root once and reuse it:

    R=~/Datasets/sheet-music-omr/v2
    SEED=20260811

### Probe first — the class census is the only check that catches a
### silent decline

A full run is an hour of MuseScore and most of a gigabyte, and the bugs
that matter here are invisible to every test that does not involve real
MuseScore. Before changing generator content, run the coverage families
alone, one face, no textures:

    P=~/Datasets/sheet-music-omr/probe
    Training/.venv/bin/python Training/generate/build_dataset.py generate \
        --root $P --seed $SEED --engines ms4 --per-face 1 --textures 0 \
        --pin-page --probe-faces "ms4=Bravura"
    OMR_DATA_ROOT=$P OMR_LABEL_EXPORT=1 swift test
    Training/.venv/bin/python Training/generate/build_dataset.py finalize \
        --root $P --seed $SEED --class-floor 70

That is ~30 renders and a couple of minutes. Read two things:

- **`tier1Missing` per render.** Anything nonzero is ink MuseScore drew
  that no detector class covers. Find the codepoint by grepping the
  render's `page_*.labels.json` for `unknown` — the name carries it
  (`unknownE044`).
- **the `[coverage-below-floor]` list against `--class-floor 70`.** With
  `--textures 0` the only classes that may legitimately miss are the
  ones the texture generator supplies (see `_TEXTURE_SUPPLIED` in
  `Training/tests/test_gen_coverage.py`). Anything else missing is a
  family that asked for ink and did not get it.

Five silent declines have been caught this way, all of which passed
every XML-level test: an invalid `<defaultClef>` token, a redundant
`<Accidental>`, an unmatched `<musicalSymbolFont>`, a `<Clef>` written
without `<transposingClefType>`, and a percussion clef change on a
pitched staff. "The XML says so" has never once been sufficient.

**1. Generate** (needs MuseScore; add the owner's originals at run time —
never a tracked path, and never a copyrighted corpus):

    Training/.venv/bin/python Training/generate/build_dataset.py generate \
        --root $R --seed $SEED --engines ms4 --per-face 2 --textures 100 \
        --extra-sources ~/Desktop/free_score

An `--extra-sources` score that carries no `<Style>` element cannot be
given a face — style is applied by rewriting that element, since
`mscore -S style.mss` is silently ignored on headless export. Such a
source is **quarantined** rather than exported in MuseScore's default
face under a `render.json` claiming the requested one; `generate` prints
`[generate][WARN] … style-not-applied: … (source … from <path>)` and the
same reason lands in `quarantine.json`. Fix or drop the named file — one
of them is enough to flip its whole face to `font-mismatch` on P3c-G4.

**2. Label export** (Swift; forced Tier 1). This is the phase boundary:

    OMR_DATA_ROOT=$R OMR_LABEL_EXPORT=1 swift test 2>&1 \
        | grep '\[SUMMARY\]' | sort > /tmp/omr-export-run1.txt

**3. Finalize** — writes the manifest and scores two gates:

    Training/.venv/bin/python Training/generate/build_dataset.py finalize \
        --root $R --seed $SEED

### Gate → command

| Gate | Command | Pass looks like |
|---|---|---|
| **P0-G1** oracle replay is exact | `OMR_DATA_ROOT=$R OMR_ORACLE_REPLAY=1 swift test 2>&1 \| grep '\[SUMMARY\]'` | every render prints `exact=Y`; the closing line reads `[gate][SUMMARY] P0-G1 exact=N/N inexact=0 skipped=0 failed=0 pass=Y` **and `N > 0`**. Read `pass=`, not the two numbers: the denominator counts every render directory visited, so a skip (label export never ran for it) or a throw (unopenable PDF) is a miss, and an empty sweep is `exact=0/0 … pass=N`, never a pass. `swift test` itself fails when `pass=N`. Measured `2208/2208 pass=Y` on v2 (2026-08-11), after the order-invariance fix — see "RESOLVED: P0-G1 failed at scale" below |
| **P0-G2** run twice, byte-identical | rerun any harness command into `…-run2.txt` and `diff` it against run 1; for the label export also `find $R -name '*.labels.json' \| sort \| xargs shasum -a 256` after each run and `diff` those | empty `diff` both times |
| **P0-G3** back-end ceiling measured | `OMR_DATA_ROOT=$R OMR_SCORE_EVAL=1 swift test 2>&1 \| grep '\[SUMMARY\]' > ceiling.tsv` and `OMR_DATA_ROOT=$R OMR_SEAM_EVAL=1 swift test 2>&1 \| grep '\[SUMMARY\]' > seam.tsv` | not a threshold — the recorded rows **are** the ceiling. Read `measuresA` / `measuresB` before any percentage (see blind spots below) |
| **P0-G4** vector path untouched | `PDF_REAL_CORPUS=1 swift test --filter "measureCorpusDiff\|measureRealCorpusDiff"`, having copied the untracked `PDFCorpusGroundTruthSpikeTests.swift` in from the MAIN checkout — its corpus paths are absolute, so it runs from anywhere. **Delete it again afterwards; it must never be committed.** | 141 `[SUMMARY]` rows (curated 6 + real 135) — count them, the real half is env-gated and silently prints nothing without the flag. Diff two sorted runs; see "P0-G4 was run" below |
| **P3c-G1** same seed ⇒ byte-identical | generate a second root with the **same seed**, run steps 2–3 over it, then `Training/.venv/bin/python Training/generate/build_dataset.py compare $R ${R}b` | `[compare][SUMMARY] identical=Y` (exit 0). Labels + manifest only; images are excluded by design. Each `finalize` also prints `[gate][SUMMARY] P3c-G1-selfcheck … pass=Y` — it re-reads the manifest it just wrote and re-hashes every label listed, so a `pass=N` there means comparing the two roots is meaningless until it is fixed (`[verify]` lines name what) |
| **P3c-G2** export success ≥ 99% | read `finalize`'s output (or `manifest.json` → `gates.P3c-G2`) | `[gate][SUMMARY] P3c-G2 export_success=… denominator=plan … missing=0 pass=Y`. `missing>0` means renders the plan drove that are neither exported nor quarantined — an interrupted `generate`, so rerun it before believing anything else |
| **P3c-G3** per-class coverage floor | same run; every shortfall prints a `[coverage-below-floor] <class> n/floor` line | `[gate][SUMMARY] P3c-G3 below_floor=0/62 unreachable=2 classes=64 floor=1000 pass=Y`. A first pilot will not pass this — the report tells you which classes to generate more of. **Read the denominator**: it is the *eligible* classes, two fewer than the vocabulary — see below |
| **P3c-G4** face actually applied | `Training/.venv/bin/python Training/generate/build_dataset.py faces --root $R` | `[gate][SUMMARY] P3c-G4 applied=N/N pass=Y` (exit 0). The count is over `confirmed=`, i.e. geometry **and** embedded font name together — see below |

### Raster front-end (P3a / P3b) — measurement probes and sweeps

The raster stage's thresholds are all measured rather than chosen, and
these are the commands that measure them. **Run every sweep in RELEASE**
(`swift test -c release`): `RasterPage.analyze` is pixel-loop-bound and a
debug build is roughly two orders of magnitude slower, which turns a
half-hour sweep into a multi-day one.

| what | command | read |
|---|---|---|
| staff-line ink continuity, and the merge tolerance it implies | `OMR_DATA_ROOT=$R Training/.venv/bin/python Training/probes/measure_staff_ink.py 30 [degraded]` | the `survival` line — the fraction of lines that stay ONE piece covering 80% of their span at each candidate tolerance. The gap percentiles above it are context, not the decision |
| stacked-beam fusion rate | `OMR_DATA_ROOT=$R Training/.venv/bin/python Training/probes/measure_beam_fusion.py 60 [degraded]` | `fusionRate`. Above ~2% the beam detector needs de-fusion — and note a fused pair is 1.25 sp, above a single-beam window, so without it the group loses EVERY level, not one |
| seam level: raster paths vs labels | `OMR_DATA_ROOT=$R OMR_RASTER_SEAM=1 swift test -c release --no-parallel --filter OMRRasterSeamEvalHarness` | one `[raster-seam][SUMMARY]` line. **Read `pages=` before any ratio** — `pages=0` means the sweep ran over nothing |
| score level: hybrid vs `source.mscx` | `OMR_DATA_ROOT=$R OMR_HYBRID_EVAL=1 swift test -c release --no-parallel --filter OMRHybridEvalHarness` | per-render rows plus `[hybrid][SUMMARY]`. **Read `measuresA`/`measuresB` before any percentage** (§8.2's blind spots apply) |
| which truth verticals the front-end drops, by length and beam relation | add `OMR_STEM_MISS_PROBE=1` to the seam command | `[stemprofile] key=<halfSpaces>\|<in\|edge\|none>`. This is what showed the miss was a pure LENGTH cliff and not a beam-relation effect |
| how far a predicted vertical's nearer END is from the notehead that would certify it | add `OMR_STEM_END_PROBE=1` to the seam command | `[endprofile] sp=… real=… false=…`. Sets `stemHeadEndToleranceInSpaces`. Run it with the length floor LOWERED, or the population it must separate is not on the page |
| per-duration histogram, hybrid or oracle | add `OMR_HYBRID_DURHIST=1` to either the hybrid or the `OMR_SCORE_EVAL` command | `[durhist] <render> 8:6037->4577 …`. Subtract the two: a duration the CEILING also loses is not this stage's to fix — 1/20, 1/28 and 64ths are 100% lost at the ceiling, so of the "2794 tuplet notes" only the ~660 triplets were ever ours |

The hybrid harness takes glyphs from the labels — a perfect detector,
restricted to the frozen detector vocabulary — and paths from the real
raster pipeline, so its delta against the P0-G3 oracle ceiling is this
stage's contribution and nothing else's. Two env vars vary it:

- `OMR_HYBRID_MODE` = `full` (default) | `noStaffLines` | `noVerticals` |
  `noBeams` | `nullFrontEnd` | `truthStaffLines` | `truthVerticals` |
  `truthBeams`. The three `no*` are the **lobotomy** checks:
  dropping one primitive must crater one specific metric (staff lines →
  pitch, verticals → measure counts, beams → duration). A mode that
  changes nothing means that primitive never reached `buildScore`.
  The three `truth*` are the **bisect**: each hands ONE primitive back to
  the oracle and leaves the rest raster, so the duration it recovers is
  that primitive's share of the loss. Run these BEFORE theorizing about
  which primitive is at fault. They answered it in two sweeps
  (verticals 16 points, beams 3) after a careful reading of the code had
  picked the wrong one.
- `OMR_HYBRID_JITTER_SP` — displaces every glyph origin by this many
  staff spaces. The hybrid otherwise feeds PERFECT origins while a real
  detector will not, and `barlineCandidates`' 2.0 / 0.6 sp windows were
  calibrated against vector geometry; sweeping σ ∈ {0.1, 0.25, 0.5}
  turns that into the detector's origin-error budget. Reported, not
  gated.

**`nullFrontEnd` is not optional.** It is the floor: if the `full`
numbers are not far above it, the harness is measuring nothing, and the
same run also catches truth paths leaking into the hybrid plumbing.

#### Measured 2026-08-14 — the current numbers

All 2028 scorable renders of v2, hybrid `full` against the P0-G3 oracle
ceiling on the same renders:

| | pitch p50 | pitch mean | dur p50 | dur mean |
|---|---|---|---|---|
| oracle ceiling | 100 | 80.5 | 82 | 72.1 |
| hybrid, 2026-08-13 | 97 | 68.8 | 55 | 52.4 |
| **hybrid, now** | **94** | **68.2** | **73** | **61.0** |

Duration closed 18 of the 27-point gap for three points of pitch median
(the mean is unchanged). Both axes now sit at ~85% of the ceiling on the
mean, where before duration was at 73% and pitch at 85% — and **that
asymmetry was the whole argument for staying in classical CV**. See
"When to start the CNN" in the round-summary.

Two changes did it, in this order:

1. **`isStem` grew a y-term** (`PDFImporter+Rhythm.swift`). It accepted
   any vertical whose x was within 1.4 sp of ANY notehead in the cell,
   with no y condition — a vector-era assumption (MuseScore strokes stems
   and draws accidentals as glyphs, so paths and glyphs are disjoint ink)
   that a raster front-end violates by construction. Now a RASTER-tagged
   vertical also needs a notehead within 0.25 sp of one of its ENDS.
   That let `verticalMinLengthInSpaces` drop 3.5 → 2.5 and stop being a
   classifier: it had been cutting ~6,200 real verticals, which was the
   largest single item in the duration gap.
2. **`extendedSpan`** (`RasterPage+BeamFit.swift`) walks a fitted beam
   out to its own outermost stems. The fit structurally cannot reach
   them, and `beamWindow` uses a beam's x-range as a tuplet's member-run
   window, so triplets were 96% lost.

The bisect that found them is the reusable part. `OMR_HYBRID_MODE` now
takes `truthStaffLines` / `truthVerticals` / `truthBeams`, which hand ONE
primitive back to the oracle and leave the rest raster; the duration each
recovers is that primitive's share of the loss. It read verticals 16
points, beams 3 — before any code changed.

Seam level, 299 pages of the 200-render subsample:

| | before | after |
|---|---|---|
| beam x-coverage p50 / p01 | 0.90 / 0.85 | **0.95 / 0.85** |
| matched beams covering ≥95% | 3103 / 6218 | **5576 / 6218** |
| truth verticals missed | 8517 | **3115** |
| barline fp | 1526 | 6889 |

The barline false positives rise BY DESIGN and are not a regression: the
front-end now emits the short verticals it used to cut, and `isStem`
rejects the false ones downstream where the noteheads are. Structure is
unaffected — exact measure counts are 142/198 before and after, because
`barlineCandidates` requires 85% of the staff height.

#### Measured 2026-08-13 — the previous freeze

Score level, hybrid vs `source.mscx`, **all 2028 scorable renders of v2**,
against the oracle-replay ceiling on the same renders:

| | pitch p50 | pitch mean | dur p50 | dur mean |
|---|---|---|---|---|
| oracle ceiling (perfect detector, perfect paths) | 100 | 80.5 | 82 | 72.1 |
| **hybrid `full`** | **97** | **68.8** | **55** | **52.4** |

Pitch is at 85% of the ceiling and within three points of it at the
median; **duration is at 73% and 27 points short**. That asymmetry is the
next lever, not a mystery: duration comes from beams and stems, and of
the 1428 renders whose duration trails the oracle, 838 have EXACTLY
matching note counts — so half the loss is mis-read note values rather
than missing content.

Seam level, all 4650 pages, run twice byte-identical:

| | clean | frozen (degraded) |
|---|---|---|
| staff-line recall | 0.7593 | 0.7119 |
| barline recall / precision | 0.9201 / 0.6740 | 0.8470 / 0.5872 |
| beam recall / precision | 0.9663 / 0.8175 | 0.6424 / 0.4867 |
| mean abs deskew angle | 0.002° | 1.004° |
| peak RSS | 361MB | 624MB |

(Those were measured before the vertical-floor change and are the
conservative figures; barline precision is low **by design** — the
front-end does not separate stems from barlines, since they overlap in
length, and leaves that to `barlineCandidates` downstream.)

**How these numbers moved, and what moved them.** The stage first
measured pitch p50 = 40 / mean 42.0 on this same sweep. Three defects
accounted for the difference, none of them in the recognition of
anything:

| fix | pitch p50 |
|---|---|
| (start) | 40 |
| stop the gap tolerance bridging ledger lines into a staff line | 49 |
| reject a dense ledger row on page-relative width | 52 |
| put the vertical floor at the shortest real vertical (2.0 → 3.5 sp) | **97** |

The last one was the only major constant in the raster front-end that had
been chosen by reasoning rather than measured, and 85% of all
false-positive verticals were sitting under it.

Two changes were tried and **reverted on measurement**, both recorded in
the source so they are not retried: dropping verticals that fall inside a
glyph's box (pitch p50 52 → 48), and capping vertical length at 11 staff
spaces (52 → 23, because the vector path emits a barline as one segment
PER STAFF while the raster merges the column, so genuine system-spanning
barlines were being counted as false positives).

The lobotomy rows are the evidence that the harness can fail, and each
craters its own metric and only its own:

| configuration | pitch p50 | dur p50 |
|---|---|---|
| `full` | 49 | 37 |
| `noBeams` | 49 (bit-identical) | 25 |
| `noVerticals` | 2 | 4 |
| `noStaffLines` / `nullFrontEnd` | *no score at all* — 180 renders throw | |

(Measured at the 2.0 floor; the shape is what matters, not the level.)

Origin-jitter, P3d's error budget:

| σ (staff spaces) | pitch p50 | pitch mean |
|---|---|---|
| 0 | 49 | 44.4 |
| 0.1 | 52 | 45.3 |
| 0.25 | 46 | 39.7 |
| **0.5** | **20** | **16.8** |

Up to ~0.25 sp of glyph-origin error is free; at 0.5 sp pitch halves.
Duration barely moves, consistent with it coming from beams and stems
rather than origins.

**Frozen eval set** (spec §6.5), after the manifest exists — degrades
every page once, with a recorded seed, into `$R/eval_frozen/`:

    Training/.venv/bin/python Training/generate/build_dataset.py freeze \
        --root $R --seed $SEED

**COCO convenience export** (the canonical label JSON stays
authoritative — COCO cannot carry paths, curves, origins, or advances):

    Training/.venv/bin/python Training/generate/build_dataset.py coco --root $R

The frozen eval set is a **separate** export — `$R/eval_frozen/` is not
walked as part of `$R` (it holds no `render.json`, by design):

    Training/.venv/bin/python Training/generate/build_dataset.py coco \
        --root $R/eval_frozen --out $R/coco-eval.json

Each frozen page's boxes are put through that page's `label_transform`,
so they land on the degraded raster. `images[].width` / `.height` are
the degraded PNG's real size; the y-flip is anchored to the **clean**
raster's size, recorded per page as `image.source_size_px` — those are
two different rasters and the homography maps between them. Read
`[coco][SUMMARY] … images=N`: a `[coco][WARN]` line means the root
yielded nothing, which is nearly always the wrong `--root`.

### Raster front-end (P3d) — the detector

The CNN symbol detector. It fills the one stream the raster front-end still
took from the labels — `WalkedContent.glyphs` — so from here the numbers are
end to end rather than hybrid.

The pipeline has **one implementation of preprocessing, in Swift**, and a phase
boundary either side of the trainer, the same shape the label export already
uses:

    1. Swift   OMR_PREP_EXPORT=1 swift test   → normalized page + targets
    2. Python  model.train / model.export     → checkpoint → .mlpackage
    3. Swift   OMR_DETECT_EVAL=1 swift test   → seam + end-to-end numbers

Step 3 takes two optional switches, both off by default and neither of which
touches the numbers:

- `OMR_DETECT_TIMING=1` adds `[detect-timing]` lines — the sweep split into
  named phases, slowest first, with a per-call mean. Use it before optimising
  anything here; the phase this section's cost table blamed for two rounds was
  0.4% of the run.
- `[detect-split]` lines are always printed: the same seam numbers partitioned
  by `prep.split_of` bucket. **Read those, not the aggregate**, for anything
  about generalization — see the seam table below for why.

Python never re-derives deskew or scale; it consumes what step 1 wrote. A
second implementation would drift, and the symptom would not be a crash — it
would read as "the detector is bad", which is exactly what cost this program a
round once before (the first degraded seam sweep read 0.20 staff-line recall
against a Python probe's 0.91, and the whole gap was an unmapped frame).

#### Prep roots (`OMR_PREP_EXPORT=1`)

    OMR_DATA_ROOT=$R OMR_PREP_ROOT=$R-prep \
    OMR_PREP_EXPORT=1 swift test -c release --no-parallel \
        --filter OMRPrepExportHarness

| root | renders | pages | glyphs | dropped_no_bbox | skipped_no_staff | skipped_implausible_scale | oversize | failed | size |
|---|---|---|---|---|---|---|---|---|---|
| clean (`v2-prep-v3`) | 2208 | 4650 | 911409 | 0 | 0 | 0 | 0 | 0 | 693MB |
| frozen (`v2-prep-frozen-v3`) | 2208 | 4637 | 908435 | 0 | 9 | **4** | 0 | 0 | 5.4GB |

What those counters answer:

- **`skipped_no_staff` 0 clean, 9 degraded.** Degradation destroys the staff
  outright on 9 of 4650 pages, so the detector never sees them and no amount of
  recognition recovers them. That is 0.19%, and it is a floor on any degraded
  number below.
- **`dropped_no_bbox=0`** over 908k glyphs — the ink-bbox chain holds at scale.
- **`skipped_implausible_scale=4`, and `oversize=0` only BECAUSE of it.** See
  below; this counter is new and it exists because the old `oversize=0` was not
  the reassurance it was read as.

**CORRECTED — `oversize=0` was unfalsifiable, not reassuring.** This section
used to say the parent design's worry that a `brace` cannot be centred inside
one tile "never happens at S=12 / T=384; do not design around it". The
regenerated degraded root reported `oversize=8` — and every one of the eight
was a `clefG` / `clefG8vb` with a rendered size of **461-729 px**, i.e. a clef
38 to 60 staff spaces tall.

They were not oversized glyphs. They were four pages whose staff spacing
`RasterPage.analyze` measured far too small, so `OMRPrepNormalize` UPSCALED
them to reach S: scale 4.00 and 3.43 (`extz_Now_is_the_time_ms4_MuseJazz_v6`
pages 9 and 48) and 2.67 twice. Every clean page sits at or below 1.5; 4628 of
4641 degraded pages do too.

The damage is not disk. A 7196x9992 normalized page yields **~736 tiles**
against a normal page's ~30, so four pages contributed on the order of 1% of
the degraded root's training tiles, every one of them teaching the geometry
heads that a notehead is four staff spaces wide — the exact head this round
fixed the targets of.

**It is not new, and it was not caused by the target fix**: the pre-existing
`v2-prep-frozen` carries the same scale 4.00 / 3.43 on the same two pages. What
changed is detectability. The old constant targets were 4.023 sp ≈ 48 px, which
cannot exceed a 384 px tile no matter how badly a page is scaled, so `oversize`
was a counter that could not move — and it was being read as evidence.

`OMRPrepExport.maxNormalizeScale = 2.0` now skips such a page and counts it.

The degraded root is 8× the clean one on disk because degradation noise does
not compress.

**STALE as of `250764b2`: these two roots and the shipped checkpoint predate a
target redefinition.** That fix wave commit changed `OMRPrepTargets.glyphs` so
`advancePx`/`renderedSizePx` are derived from the label bbox's MAPPED corners
instead of `advancePt`/`renderedSizePt` scaled directly by `dpi/72 * scale`.
That was the right fix — the raster contract (`GlyphGeometry`'s own doc comment in
`Sources/SheetMusicPDF/Import/Internal.swift`) defines `advance` as the ink
bbox WIDTH and `renderedSize` as its HEIGHT, and the two were never equal:
`renderedSizePt` (`OMRLabelSchema.swift`, `Double(g.geometry.renderedSize)`)
comes from the vector oracle's em/rendered size — roughly 4 staff spaces for
a notehead — while the ink bbox height is roughly 1. So the `renderedSize`
regression channel's targets change by ~4×, on clean pages as well as
degraded ones (the old shortcut only happened to agree with the mapped-corner
length under an identity `label_transform`).

**Measured on `v2-prep` as it stands, the old targets are worse than "off by a
factor": they are two class-INDEPENDENT constants.** Over 40 pages, every class
reports the same `rendered_size_px / staff_space_px` and the same
`advance_px / staff_space_px`:

| class | n | renderedSize/sp | advance/sp |
|---|---|---|---|
| noteheadBlack | 7816 | 4.023 | 2.012 |
| accidentalNatural | 3908 | 4.023 | 2.012 |
| accidentalFlat | 977 | 4.023 | 2.012 |
| clefG | 376 | 4.020 | 2.010 |

The label file's `rendered_size_pt` is exactly `2 x advance_pt` for every glyph,
and both come from the font's em metrics rather than from ink — while the real
ink bbox varies a lot by class (on one page: `clefG` bbox height 24.58 pt
against a recorded 15.52, `noteheadBlack` 5.98 against 18.26). **The geom head
was therefore trained to regress the same two numbers for a notehead and for a
clef.** Regeneration is not housekeeping.

Both prep roots above and the checkpoint (`~/omr-models/run1`) were
exported/trained BEFORE this fix, so they carry the OLD `renderedSize`
targets. **Every number frozen in this document is unaffected**, and stays
reproducible against that checkpoint: `OMRPrepTargets` sits upstream of
training only — nothing on the evaluation path calls
`OMRPrepTargets.glyphs(...)`. `OMRDetectorFrontEnd` (what the eval harness
runs) consumes only `OMRPrepTargets.trainableVocabulary`, the class list,
which this fix did not touch.

The hazard is the NEXT training round: retraining against `v2-prep` /
`v2-prep-frozen` as they stand would train a new model against targets the
code no longer produces — no error, no diagnostic, just a systematically
wrong `renderedSize` head. **Regenerate both prep roots before the next
training run**, same commands as above, pointed at the frozen eval set for
the degraded root:

    OMR_DATA_ROOT=$R OMR_PREP_ROOT=$R-prep \
    OMR_PREP_EXPORT=1 swift test -c release --no-parallel \
        --filter OMRPrepExportHarness

    OMR_DATA_ROOT=$R/eval_frozen OMR_PREP_ROOT=$R-prep-frozen \
    OMR_PREP_EXPORT=1 swift test -c release --no-parallel \
        --filter OMRPrepExportHarness

Measured 2026-08-18 on the regenerated roots: **17.7 min clean, 18.6 min degraded**
(`renders=2208 pages=4650 glyphs=911409 dropped_no_bbox=0 skipped_no_staff=0
oversize=0 failed=0`, 693 MB — every counter identical to the old root, as it
must be: the same pages with different TARGET VALUES).

That the values really did change is the point, and it is visible per class.
The old root reported the same two ratios for every class; the new one reports
the glyph's actual ink:

| class | old renderedSize/sp | new | old advance/sp | new |
|---|---|---|---|---|
| noteheadBlack | 4.023 | **1.095** | 2.012 | **1.303** |
| accidentalNatural | 4.023 | **3.067** | 2.012 | **0.693** |
| accidentalDoubleSharp | 4.023 | **1.164** | 2.012 | **1.089** |

A notehead about one staff space tall and 1.3 wide, a natural tall and narrow,
a double sharp a small square — which is what those glyphs are.

**A frozen render's `source_id` also changed**, and that one is not cosmetic.
`frozen.json` carries no provenance, so the export used to write the RENDER id
into `source_id`; `prep.split_of` is keyed on `(source_id, page_index)`
precisely so that one source rendered under eight faces cannot straddle the
train/val boundary, and a render id in that field made the degraded root split
per render — the exact thing that keying is there to prevent. It is now
recovered from the render id (`{source_id}_{engine}_{face}_v{n}`, checked
against all 2208 renders that record one: 2208 agree, 0 disagree). `face` stays
empty for a frozen render, because the render id spells `Finale Broadway` as
`FinaleBroadway` and 552 of those 2208 cannot round-trip — an empty face is
honest, a de-spaced one is wrong.

**Training on both roots together** is what that fix enables. `--prep-root`
takes several, concatenated in order, and the split is stable across them, so a
page held out of the clean root is held out of the degraded one:

    Training/.venv/bin/python -m model.train \
        --prep-root $R-prep-v3 $R-prep-frozen-v3 \
        --out ~/omr-models/run2 --epochs 8 --seed 20260811 --workers 8

#### Measured 2026-08-15 — the first end-to-end numbers

Model: `SymbolNet`, CenterNet-style, stride 4, 62 classes (the frozen 64 minus
`fine` / `toCoda`). Trained on the clean prep root, 8 epochs, batch 16,
lr 1e-3 cosine, seed 20260811, MPS.

**Seam level** — detections against the label glyphs. Both rows are the same
binary over the same 34 renders / 69 pages:

| | recall | precision | mean origin err |
|---|---|---|---|
| clean | 0.9657 | 0.9355 | **0.0705 sp** |
| degraded (frozen) | 0.6676 | 0.8887 | 0.1005 sp |

> **Read these two rows as MOSTLY TRAINING-SET numbers.** The eval sets are a
> hand-made 34-render subsample of the whole dataset and nothing about their
> construction respected `prep.split_of`: **55 of their 69 pages (80%) hash into
> `train`**, 9 into `val`, 5 into `test`. `OMRDetectorEvalSweep` sweeps whatever
> directory it is handed and had no notion of the split; it now partitions the
> same run and prints a `[detect-split]` row per bucket
> (`OMRDatasetSplit`, the Swift side of `prep.split_of`, pinned to a
> Python-generated table). Same binary, same pages, same run:
>
> | | pages | recall | precision | mean origin err |
> |---|---|---|---|---|
> | clean — train | 55 | 0.9879 | 0.9658 | 0.0702 |
> | clean — val | 9 | **0.8563** | **0.8563** | 0.0676 |
> | clean — test | 5 | 0.9576 | 0.8306 | 0.0767 |
> | degraded — train | 55 | 0.6610 | 0.9004 | 0.1077 |
> | degraded — val | 9 | 0.6413 | 0.8396 | 0.0809 |
> | degraded — test | 5 | 0.7580 | 0.8772 | 0.0767 |
>
> **`val` is 9 pages and `test` is 5 here, and those two rows are noise.**
> Read the large-sample table below instead; it was measured as soon as the
> sweep became cheap enough to run one, and it does not say what these rows
> appear to say.

#### Held out at scale — the same checkpoint, 1336 pages

`~/Datasets/sheet-music-omr/v2-eval-holdout{,-frozen}`: 54 renders selected for
carrying held-out pages, 1336 pages swept, **300 of them held out** (99 val +
201 test). Same binary, same `run1` checkpoint, 5 minutes per row.

| | split | pages | recall | precision | mean origin err |
|---|---|---|---|---|---|
| clean | train | 1036 | 0.9934 | 0.9723 | 0.0622 |
| clean | **val** | 99 | **0.9933** | 0.9714 | 0.0625 |
| clean | test | 201 | 0.9879 | 0.9570 | 0.0619 |
| degraded | train | 1036 | 0.8805 | 0.9530 | 0.0835 |
| degraded | **val** | 99 | **0.8820** | 0.9510 | 0.0817 |
| degraded | test | 201 | 0.8747 | 0.9474 | 0.0824 |

**There is no train/held-out gap** — clean val recall 0.9933 against a train
0.9934, degraded 0.8820 against 0.8805. The 80% training share of the eval set
is real, but the inflation it suggests is not: at this sample size the detector
generalizes, and the earlier "13-point gap" was one bad page out of nine.

Note also how far the absolutes move between populations: clean recall 0.9657
on the 34-render subsample against **0.9926** here, degraded 0.6676 against
**0.8798**. Those are different populations, not different detectors — the same
`.mlpackage`, the same day. **Never compare a number from one of these tables
against a number from the other.**

What is left after the partition is the one gap that is real: **degradation
costs about 11 points of recall** (0.9926 -> 0.8798) on a model that has never
seen a degraded page. Precision barely moves (0.9701 -> 0.9521), so the failure
is missed symbols, not invented ones.

One thing the partition does NOT explain: the training curve's val LOSS rises
monotonically from epoch 1 while val RECALL matches train recall exactly. The
loss is being driven by something other than detection quality — confidence
calibration, or the regression heads, both of which the seam metric is blind
to. **That was resolved by the next run; see "Selecting on val loss was
wrong".**

#### RESOLVED — selecting the checkpoint on val loss was wrong

`run2-clean`: the corrected targets, everything else identical to `run1`
(8 epochs, batch 16, lr 1e-3 cosine, seed 20260811, clean root only). Its val
loss is best at epoch 1 (0.3869) and worse afterwards, ending at 0.4263 —
so `_save_checkpoint`'s best-val rule ships epoch 1. Both checkpoints were then
measured on the 1336-page held-out set, same binary, same day:

| clean, val split (99 pages) | recall | precision | mean origin err |
|---|---|---|---|
| `run1` (old targets, shipped) | 0.9933 | 0.9714 | 0.0625 |
| `run2` **best-val**, epoch 1 | 0.9952 | 0.9863 | 0.0534 |
| `run2` **last**, epoch 7 | **0.9966** | **0.9964** | **0.0339** |

Over the whole 1336 pages, epoch 7 against epoch 1: **false positives
3636 -> 744 (-80%)**, false negatives 1752 -> 678 (-61%), origin error
0.0536 -> **0.0332 sp (-38%)**.

**The epoch with the WORST val loss is far the best detector.** Detection
quality improved monotonically across all 8 epochs while the loss rose. The
previous round's reading — "textbook overfitting, every number comes from one
effective epoch" — was an artifact of this selection rule, not a property of
the training: `run1` shipped its epoch-0 weights for the same reason.

Consequences, in order of how much they cost:

1. **Ship `checkpoint_last.pt`.** Every comparison from here (the mixed-root
   and augmentation runs) must be read off the last epoch, or it measures the
   selection defect instead of the change under test.
2. **Origin error is now 0.0332 sp, 7.5x inside the 0.25 sp budget** (`run1`
   was 3.4x).
3. The trainer still selects on val loss. Selecting on held-out seam recall
   would mean calling the Swift eval from the training loop — a phase boundary
   this pipeline deliberately keeps — so for now `checkpoint_last.pt` is
   written every epoch and the choice is left to the eval.

**But not on degraded input**, and that is a real trade, not a rounding error:

| degraded, val split (99 pages) | recall | precision | mean origin err |
|---|---|---|---|
| `run1` | 0.8820 | 0.9510 | 0.0817 |
| `run2` best-val, epoch 1 | 0.8703 | 0.9634 | 0.0807 |
| `run2` last, epoch 7 | 0.8480 | **0.9793** | **0.0678** |

Training longer on clean pages buys precision and localization everywhere and
**spends degraded recall**: 0.8820 -> 0.8480. The clean-to-degraded gap widens
from 11 points to **14.9** (0.9966 vs 0.8480) — which is exactly the argument
for the mixed-root run below, and that run settles it.

#### RESOLVED — the degraded gap closes by training on degraded pages

`run3-mixed`: identical to `run2-clean` except that `--prep-root` names BOTH
the clean and the degraded prep export, with `--samples-per-epoch` pinned to
`run2`'s 110158 so the two runs take the same number of optimizer steps and the
data mix is the only difference. Held-out val split, 99 pages, last epoch:

| val split | `run1` | `run2` clean-only | **`run3` clean+degraded** |
|---|---|---|---|
| clean recall | 0.9933 | 0.9966 | **0.9974** |
| clean precision | 0.9714 | 0.9964 | 0.9958 |
| clean origin err | 0.0625 | 0.0339 | **0.0331** |
| degraded recall | 0.8820 | 0.8480 | **0.9884** |
| degraded precision | 0.9510 | 0.9793 | 0.9850 |
| degraded origin err | 0.0817 | 0.0678 | **0.0386** |
| **clean-to-degraded recall gap** | 11.1 pt | 14.9 pt | **0.9 pt** |

**Degraded recall +14 points, degraded origin error −43%, and nothing given up
on clean.** Recall and precision rise together, so this is not a threshold
trade — it is capability the clean-only model did not have.

The experiment was only possible because of the `source_id` fix above. With the
render id in that field the degraded root split per render, so the same
engraving sat on both sides of the train/val boundary and a mixed-root run's
held-out number would have measured nothing.

**Read the degraded row for what it is.** `run3` trains on pages degraded by
`generate/profiles/scanner.toml` and is evaluated on pages degraded by the same
profile. That is robustness to THAT corruption, not to scanning in general —
"trained on the test transform" in the part of the pipeline where it matters
most. Whether robustness transfers to a corruption never trained on is a
separate question, and it is what `--augment photometric` is for: its ranges are
deliberately not read from `scanner.toml`, so a clean+augmentation run evaluated
on the degraded set measures transfer rather than memorisation.

#### Where the duration deficit actually is — measured, not reasoned

Duration sits at p50 0.72 while pitch is 0.94, and a PERFECT detector moves the
duration median by nothing. So the deficit is not in the CNN. `truthPaths` (a
new mode: every path kind from the oracle, which with label glyphs makes the
front-end fully oracular) puts a number on the rest, over the 34-render
`v2-eval` set that carries the loss:

| front-end | pitch p50 | dur p50 |
|---|---|---|
| `full` — label glyphs, raster paths | 96.0 | 72.0 |
| `truthPaths` — fully oracular | 100.0 | **82.0** |

**The duration ceiling is 82, not 100.** So of the 28-point deficit, **18 points
are lost upstream of the front-end entirely** — in `buildScore`, or in what the
labels can express — and only **10 points** are the raster path front-end's to
recover. Pitch, by contrast, reaches its ceiling exactly when the paths are
perfect, so pitch IS a front-end problem and duration mostly is not.

Per-primitive substitution, paired per render against `full` (n=32):

| substituted from the oracle | dur mean delta | renders better / worse |
|---|---|---|
| verticals (stems) | **+4.2** | 16 / 1 |
| staff lines | +2.8 | 4 / 1 |
| beams | +2.6 | 15 / 0 |

Those sum to ~9.6 against a 10-point front-end deficit, so within the front-end
the three primitives are close to additive, and stems are the biggest single
item. Staff lines move only 4 renders of 32 — a narrow, not a broad, effect.

**What the 18 upstream points are.** `OMR_HYBRID_DURHIST=1` prints each
render's authored-vs-composed duration histogram; differencing the ceiling
against `full` attributes every missing note:

| duration | short at ceiling | short at `full` | attributable to front-end |
|---|---|---|---|
| eighth | 446 | 513 | 67 |
| `1/28` (septuplet) | 252 | 252 | **0** |
| 64th | 192 | 192 | **0** |
| `1/20` (quintuplet) | 165 | 165 | **0** |
| 32nd | **0** | 160 | **160** |
| **total** | **1182** | 1464 | 282 |

**81% of all missing notes are already missing at the ceiling.** Three distinct
upstream defects account for them, and they are unrelated to each other:

1. **5- and 7-tuplets are not composed.** `1/20` short by 165 against 16ths
   over-produced by 190; `1/28` short by 252 against 32nds over by 227. Each
   tuplet note lands at its nearest plain duration. Triplets (`1/12`) are short
   by only 11, so the existing triplet support works and nothing above 3 does.
   428 notes across 18 renders.
2. **64th notes become quarters** — 192 notes, all in `cov_flags`, whose notes
   are otherwise all present (352 -> 352) with duration at 45%. At the ceiling
   the `flag64th*` glyphs are perfect, so this is `buildScore` ignoring the
   flag count, not a recognition failure.
3. **Percussion staves lose ~86% of their notes** (below).

#### Percussion staves are broken in the importer

The renders whose note COUNT collapses are all drum staves, and they are the
biggest single drag on the ceiling's mean (p50 82 vs mean 72.8):

| render | measures | notes authored -> composed | pitch | dur |
|---|---|---|---|---|
| `tex_0029` | 15 -> 15 | 114 -> **16** | 0% | 7% |
| `tex_0009` | 13 -> 13 | 89 -> **20** | 0% | 6% |

Probed directly (oracle replay, no raster, no detector): the glyphs are all
there — `tex_0029` walks 112 `noteheadXBlack` + 2 `noteheadXHalf` +
3 `clefPercussion` — and the part is correctly recognized as a drum kit
(`useDrumset: true`, a populated `drumLineMap`). The composed measures are
nearly empty regardless: `m1` and `m3` hold nothing at all, `m2` holds two
eighths, against 8 authored notes per measure.

Every surviving note is **MIDI 44**. In `percussionMidi` that is the
`stepsAbove <= 0` branch — "pedal hi-hat, below the staff" — so every notehead
is reading as below the staff bottom, which points at `anchor.bottomY` being in
a different frame from `noteheadY` rather than at any per-note decision.
`decodePercussion` itself keeps every notehead it is given, so the 86% that
never arrive are lost before it.

This is the shipped importer, not an OMR-specific path, and nothing in the
corpus gates covers percussion — which is why it survived this long.

**The origin figure is what this stage existed to obtain.** P3a/P3b's
origin-jitter sweep measured that up to ~0.25 staff spaces of glyph-origin
error is free and 0.5 sp halves pitch; a real detector lands 3.4× inside that
budget (`run1`) — **7.5× once the targets were corrected and the last epoch was
used instead of the best-val one**, and stays inside it under degradation. `barlineCandidates`' 2.0 / 0.6 sp
windows, calibrated against vector geometry, survive a real detector.

Note the shape of the degraded loss: **precision barely moves while recall
falls.** The detector goes quiet rather than hallucinating. What the next round
is fighting is misses, not false positives.

**Score level** — the composed `Score` against `source.mscx`, 32 scored
renders. The middle row is the same run with the glyphs taken from the labels
instead, i.e. a *perfect* detector on identical input, and is the only
legitimate denominator here:

| | pitch p50 | pitch mean | dur p50 | dur mean |
|---|---|---|---|---|
| floor — untrained model | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| label glyphs (perfect detector) | 0.9600 | 0.7375 | 0.7200 | 0.6300 |
| **detector glyphs** | **0.9437** | **0.7073** | **0.7251** | **0.6200** |

**A real detector costs about two points of pitch against a perfect one, and
nothing at the duration median.** The label-glyph row is aggregated from the
per-render integer percentages, so it sits within ~0.005 of what the harness
would print; both rows went through the identical script, so the delta is
sound even though the absolutes are coarse.

Do **not** compare these against the 2028-render rows in the P3a/P3b section
above. Different populations. Everything in this section is the 34-render
subsample, and the frozen numbers are only ever compared within it.

#### Gates

| gate | how | verdict |
|---|---|---|
| **P3d-G1** the detector is really in the loop | export an untrained net through the identical path and sweep first | PASS — floor detects **0** of 8520 truth glyphs, trained detects 7992. But note a zero floor makes this gate weak: anything nonzero clears it. The stronger anti-vacuity evidence is the label-replay test below |
| **P3d-G2** preprocessing has one implementation | `swift test --filter OMRPrepExport…` plus the inference path reproducing `prep.png` byte-for-byte | PASS (23 tests) |
| **P3d-G3** vocabulary parity | `swift test --filter OMRDetectorFrontEndTests` | PASS 5/5 in the `OMRDetectorFrontEndTests` struct itself — a fifth case (asserting the reordered-list error names the differing index and both class names, not merely that it throws) was added since this row was last recorded. The load-bearing case is still the **reordered** list — a count- or set-based check passes it, full-array equality does not. (The same filter command also sweeps the file's `OMRDetectorFrontEndNumericsTests` / `…ManifestDecodeTests` / `…ModelTests` suites — separate, non-vocabulary coverage added the same round; all pass, one skipped without `OMR_MODEL_ROOT`) |
| **P3d-G4** run twice, byte-identical | run the sweep twice, `diff` the sorted summaries | PASS, and the caveat this row used to carry is now resolved: `[detect-seam][SUMMARY]` no longer carries `peakRSS` — it moved to its own `[detect-rss]` line (`OMRDetectorEvalTests.printSeamSummary`), specifically because this gate diffs the summary line byte-for-byte. A process measurement can no longer land inside the diffed line. Not re-measured this round; the fix removes the field that was the entire caveat |
| **P3d-G5** vector path untouched | `PDF_REAL_CORPUS=1` corpus run, diffed against a baseline | PASS — **141 rows byte-identical**. Baseline is a scratch worktree at this round's own base commit; `main` is NOT usable, it is far ahead of the branch and `Import/` alone differs by 70+ lines |

The anti-vacuity test that matters more than G1: feeding the composer a detector
that returns exactly what the label path would have used must produce a
**bit-identical** `WalkedContent`. If it does not, the swap itself perturbs the
result and every number the mode reports carries an unknown offset.

#### Traps this round walked into, so the next one does not

- **The detector sweep walked `renderDirectories` and so never saw the frozen
  set**, printing `pages=0 renders=0 recall=0.0000` — an empty traversal wearing
  the costume of total failure. `OMRHarnessDirectoryWalk` documents this exact
  trap on `renderOrFrozenDirectories`, and the P3a/P3b seam harness already used
  the right variant. Widening the walk alone is not enough: a frozen render has
  **no `source.mscx`** (`freeze` does not copy it), so the sweep now reports
  three outcomes — `scored` / `seamOnly` / `failed` — and prints `n/a`, never
  `0.0000`, when nothing was scored.
- **A clean run and a degraded run over the same renders disagreed on the page
  count (42 vs 69)** because the pre-fix harness checked for `source.mscx`
  *before* the seam loop, silently excluding the 2 of 34 renders that carry
  `source.mscz`. Comparing those two rows would have overstated the cost of
  degradation. Both rows above are re-measured from the same binary.
- **Six tests in this round passed unchanged when the mechanism they named was
  deleted.** The most expensive was the focal loss's penalty-reduction test:
  removing `(1 - target)^4` — the term that makes a 55,675-to-16 class imbalance
  trainable — left it green, because its separation came from the `target == 1`
  branch rather than from the weighting of two negative cells. The most
  instructive was `test_masked_l1_ignores_everything_outside_the_mask`: its
  fixture (`pred = 5` everywhere, `target = 0` everywhere) made the masked mean
  and the unmasked mean both exactly 5.0, so deleting the masking entirely
  produced the same passing assertion by coincidence. Masking is what keeps
  the offset and geom heads from being trained to regress zero at every empty
  cell — and origin error is this round's headline number — so a test that
  cannot tell "masked" from "not masked" apart was silently certifying the
  one mechanism this stage's result depends on most. Every test guarding a
  mechanism now carries a recorded break-and-restore round trip.

#### Costs — RESOLVED, and the diagnosis that was recorded here was wrong

This section used to read "53 s/page … one Core ML prediction per tile" and name
**batched tile prediction** as the next round's entry point. That attribution was
never measured against the alternatives, and it was wrong. Measured with
`OMR_DETECT_TIMING=1` (`OMRDetectTiming`, which splits the sweep into named
phases), over the same 34 renders / 69 pages:

| phase | before | after | note |
|---|---|---|---|
| **whole sweep** | **545.9 s** (7.9 s/page) | **18.3 s** (0.27 s/page) | **29.8x** |
| `detect.decode` | 130.80 ms/tile | **0.44 ms/tile** | **297x** — 96% of the old sweep |
| `detect.predict` (Core ML) | 0.75 ms/tile | 0.61 ms/tile | **0.4% of the old sweep** |
| page-detections | 111 for 69 pages | 69 for 69 pages | the score pass re-detected |
| `analyze` | 193 ms/page | 158 ms/page | now the largest single phase |

Two changes, both semantics-preserving, and verified as such: **all 90 result
rows** (`[detect-seam][SUMMARY]`, every `[detect-split]`, every `[detect-class]`,
every per-render `[SUMMARY]`) are **byte-identical before and after**.

1. **`OMRDetectorDecode.decode` fused the NMS pass into the threshold scan.**
   The separated form built a 9-element neighbour array for every one of the
   62 x 96 x 96 cells — over 20 million array allocations per page — and ran the
   neighbourhood test on all of them, when on a trained heatmap almost every cell
   is far below the threshold and can never be a candidate whatever its peak
   status. (Skipping the test below the threshold is exact only for a
   non-negative threshold; `checkNumerics` now requires `threshold` in `[0, 1)`,
   which the sigmoid heatmap satisfies anyway.)
2. **The score pass reuses the seam pass's detections** (`OMRPrecomputedDetector`)
   instead of running the detector a second time over the same pages. It is a
   frozen per-render dictionary that THROWS for a page it was not given, not a
   self-filling cache that could answer a later render's page 0 with an earlier
   render's glyphs.

Training was the other blocked path, and its recorded diagnosis was closer but
still not the mechanism: the loader is slow not merely because `num_workers=0`,
but because **`dataset._load_tile_image` decodes the WHOLE page PNG for EVERY
tile**, and a page carries ~30 tiles. Measured at batch 16 over 192 pages:

| | ms/batch | ms/tile | full-epoch equivalent |
|---|---|---|---|
| `num_workers=0` | 359.1 | 22.4 | 52.2 min |
| `num_workers=4` | 125.2 | 7.8 | 18.2 min |
| `num_workers=8` | 65.2 | 4.1 | **9.5 min** |

17.9 ms of that 22.4 ms is the PIL decode. `--workers` (default `cpu_count - 2`,
capped at 8, with `persistent_workers` — macOS SPAWNs workers, so each one
re-imports torch and unpickles the dataset) is a **5.5x** on the loader and
provably not a results knob: `test_loader_batches_are_worker_count_invariant`
pins batch-for-batch equality at 0 and 2 workers. Separately, converting only
the CROP to float32 rather than the whole page is a further 1.21x
(9.08 -> 7.52 ms) for a bit-identical tile.

| | measured |
|---|---|
| detector eval | **0.27 s/page** — a full 4650-page sweep is ~21 min, was ~22 h |
| training | **~9.5 min/epoch** loader-side at 8 workers, was ~46-52 min |
| prep export | **17.7 min clean, 18.6 min degraded** (2026-08-18 re-measure; the 51/39 min recorded earlier was never re-taken after the harness changed) |

**§11's four open parameters are no longer blocked by wall clock.**
`model.json` still carries `decode_defaults_measured: false` because the sweeps
have not been run yet, not because they cannot be.

#### What the training curve says

    epoch=0 train=0.6066 val=0.3944   <- best, and the checkpoint that ships
    epoch=1 train=0.1599 val=0.4066
    epoch=2 train=0.1188 val=0.4214
    epoch=3 train=0.0968 val=0.4282
    epoch=4 train=0.0813 val=0.4230
    epoch=5 train=0.0688 val=0.4365
    epoch=6 train=0.0596 val=0.4505
    epoch=7 train=0.0541 val=0.4450

Textbook overfitting from epoch 1: train falls 11×, val rises monotonically.
So **every number above comes from one effective epoch.** A too-high learning
rate was the first hypothesis and it is wrong — that would show as an unstable
*train* loss, and train falls smoothly. The model is memorising.

**The mechanism, checked rather than guessed: `Training/model/` contains no
augmentation of any kind** — grep it for augment / jitter / noise / brightness
and nothing comes back. The earlier note here said "augmentation is
photometric-only by design"; that describes `generate/profiles/scanner.toml`,
which degrades pages when the DATASET is built, not anything applied while
training. `run1-train/train.log` confirms the training root:
`"prep_root": ".../v2-prep"` — the **clean** export, 8 epochs, nothing else.

So the model was fitted on undegraded pages with no augmentation. **What that
does NOT explain is memorization**: the 1336-page held-out table above shows no
train/held-out gap at all, on either clean or degraded pages. Whatever the
rising val loss is measuring, it is not detection quality on unseen pages.

What it does explain is the gap that survived the partition — **11 points of
recall lost to degradation** (0.9926 clean -> 0.8798 degraded), with precision
barely moving, i.e. the model goes quiet on a corruption it has never seen one
example of. That is what `--augment photometric` and training on the degraded
root's train split are aimed at, and they are aimed at that alone. Neither is
justified by "the model is memorising" — that claim did not survive its own
measurement.

The content-diversity concern stands on its own and is unmeasured either way:
~140 sources inflated by face × dpi, so a held-out page of a source sits close
to that source's training pages. Note this is a reason the held-out rows above
might FLATTER the model, not a reason they are noisy — a source-level holdout
would be the stricter test.

**RESOLVED — the empty val split now refuses.** A `--limit` small enough to
empty the val split used to report `val_loss=nan` in every epoch line, never
beat `best_val = inf`, and still write `checkpoint.pt` — from the LAST epoch's
weights, carrying `val_loss: None`, with nothing in the exit code or the file
set to distinguish it from a healthy run. `train.main` raises instead, and the
message quotes the `--limit` that caused it.

#### Augmentation (`--augment photometric`) — built, not yet measured

`Training/model/augment.py`. Five independent ops, applied in scan order —
gain/bias about mid-grey, gamma, gaussian blur (sigma up to 1.1 normalized px,
under a tenth of a staff space at S=12), additive gaussian noise, and
salt-and-pepper speckle. `--augment` defaults to `none` so a run stays
comparable with the pre-augmentation checkpoints; the default is expected to
change once the two have been measured against each other **on the held-out
split**.

Three properties are deliberate and each is pinned by a test with a recorded
break-and-restore round trip:

- **Photometric only.** Every op is a per-pixel or per-neighbourhood intensity
  change, so it moves no glyph and the heatmap / offset / geom / mask planes
  stay exactly correct. A geometric op would have to transform those four
  target planes too, and a mismatch there does not crash — it trains the
  geometry heads against the wrong answer. `test_photometric_augmentation_
  moves_no_ink_and_no_target` locates the ink in the augmented tile and
  requires its centroid to hold, because asserting only "targets unchanged"
  passes under a geometric op as well.
- **Train split only**, refused for `val`/`test` at construction. An augmented
  validation loss is not comparable across epochs, and comparing it across
  epochs is exactly how the checkpoint is chosen.
- **Wider than the eval corruption, and not read from
  `generate/profiles/scanner.toml`.** Reproducing the frozen set's own
  parameters would make a degraded-set improvement partly a measurement of
  training on the test transform.

The augmentation RNG is one `random.Random` per worker process, drawn from per
call — not seeded per item (that would give every tile the same corruption
every epoch, i.e. a once-corrupted dataset rather than augmentation) and not
reset per epoch (`persistent_workers=True` keeps worker processes alive, so a
`set_epoch()` on the main-process dataset would be a silent no-op in the copies
the workers hold). A run is reproducible for a fixed (seed, workers).

### RESOLVED: P0-G1 failed at scale — `buildScore` was not order-invariant

Measured 2026-08-11 on the 2208-render v2 dataset, the first time the
gate had been run at scale, and fixed the same day by canonicalizing the
four `WalkedContent` streams once inside `buildScore`
(`Sources/SheetMusicPDF/Import/PDFImporter+Canonical.swift`):

    before: [gate][SUMMARY] P0-G1 exact=1574/2208 inexact=634 pass=N
    after:  [gate][SUMMARY] P0-G1 exact=2208/2208 inexact=0   pass=Y

**P0-G4 was run, and it decided the canonical order.** The corpus
harness is untracked in the MAIN checkout, but its corpus paths are
absolute, so copying `PDFCorpusGroundTruthSpikeTests.swift` into this
worktree's `Tests/` is enough to run it here — it compiles against the
current `Sources/` unmodified. **Delete it again afterwards: it hard-codes
personal paths and must never be committed.** The real-corpus half is
env-gated, and without the flag it returns instantly and prints nothing,
so a run that covers only the curated 6 looks exactly like a full one —
count the `[SUMMARY]` rows (141, not 6):

    PDF_REAL_CORPUS=1 swift test \
        --filter "measureCorpusDiff|measureRealCorpusDiff" > out.txt 2>&1
    grep '\[SUMMARY\]' out.txt | sort > sums.txt   # then diff two of these

Measured against the pre-canonicalization baseline over all 141 scores:

    top-first  (-y):  13 scores moved, 12 of them WORSE (dur% -1..-3)
    bottom-first(+y):  3 scores moved, ALL BETTER, none worse

so the shipped decode is now strictly better than before the change, and
there is nothing left to re-bless. The direction was chosen by that
measurement and by nothing else — see `PDFImporter+Canonical`'s doc
comment for why the first notehead of a same-x cluster is load-bearing.

**Synthetic data could not have decided this.** The same sweep over v2
(`OMR_SCORE_EVAL`) gave **2192 byte-identical `[SUMMARY]` rows** across
both orders and the pre-fix code — 2032 scorable renders, 8 faces, 3 dpi
— because generated engraving stacks far fewer noteheads at one x than
real engraving does. And the invariance gate cannot choose either: P0-G1
reads 2208/2208 for both total orders. Only the real corpus separates
them. The rest of this section is kept because it is the
diagnosis, and because the same failure mode will come back the moment a
new pass reads a stream in arrival order.

The original finding:

The failures are the *texture* sources and a few of the owner's real
scores; every one of the 28 coverage sources replays exactly. The two
walks differ only in the ORDER of the glyph / path / text streams — a
label file is position-sorted, a direct walk is content-stream order —
so 634 renders decode to a different `Score` depending on the order
their input arrives in. First-divergence classification: durationType
366, pitch 172, dots 58, Chord-vs-Rest 14, Note-vs-Lyrics 11,
Accidental 6, and a tail.

**Why it matters more than a failing gate.** A raster detector cannot
reproduce content-stream order — it finds glyphs on a page. The raster
program's entire premise is that the same `buildScore` back-end turns
detector output into a `Score`, which requires that output to be a
function of the CONTENT, not of the arrival order. P0-G1 exists to
detect exactly this, and it did.

**Mechanism, confirmed.** `PDFImporter+Rhythm.swift:25-27` sorts a
measure's glyphs by `origin.x` alone. That is a single key, so it is not
a total order — a chord's stacked noteheads, a notehead and its
accidental, a notehead and its augmentation dot all share an x — and
Swift's `sorted(by:)` is not a stable sort. The relative order of
equal-x glyphs after the sort is therefore a function of the order they
went in. About thirty comparators of the same shape exist across
`Sources/SheetMusicPDF/Import/`; `+Rhythm.swift:247` is the one that is
already a total order, having been fixed for an earlier instance of this
same bug, and its doc comment is the precedent for how to choose a
tiebreak (in particular: **not** geometric y, which is not a total order
either).

**Not a regression from the coverage round.** The texture renders
contain none of the recently-classified ink — no `dynamic`,
`articulation`, `ornament`, `dalSegno`, `daCapo`, `repeatBarlineDots` or
`fermata`, and no `unknown*` at all, across 1944 pages — so the
classifier change is provably a no-op for them.

**Why the fix is one sort and not thirty comparator repairs.** Most of
the order-dependent decisions are not sorts at all — they are first-min
scans, greedy loops that consume candidates in arrival order, and
"break at the first content glyph" scans in the clef / key / time
readers, none of which a comparator change reaches. And two comparators
sort on an epsilon band (`|Δy| > ε ? y : x`), a relation that is not
transitive and therefore not a strict weak ordering at all, which no
extra key repairs. One sort at the boundary reaches every one of them,
because each array a pass sees is an order-preserving `filter` of one of
the four streams.

**Keeping it fixed.** `PDFImporterStreamOrderInvarianceTests` shuffles
all four streams with a seeded generator and asserts `Score` equality,
in milliseconds. Note its fixture is built to CONTAIN a consequential
tie — two noteheads at one x plus a dot straddling `applyDots`'
`dy < 4` window — because the first version of that test passed before
the fix, which is exactly the vacuous shape the older reverse-order
check in `OMROracleReplayUnitTests` had all along. A new order-invariance
test that passes immediately is a test that is not testing anything.

### P3c-G3 in detail — the floor, and the two classes exempt from it

The floor is per class, over the whole dataset. A source is rendered
once per face per `--per-face` variant, so at the standard
`--engines ms4 --per-face 2` that is **16 renders**, and a class needs
**63 instances per render** to clear 1000. `gen_coverage` sizes every
family against `PER_RENDER_TARGET = 70` and
`test_every_coverage_class_clears_the_per_render_target` fails if one
slips under — so a shortfall in this gate now means the ink did not
reach the page, not that the source never asked for it.

**Two classes are exempt and always will be.** `fine` and `toCoda` have
no SMuFL glyph: the specification has only `coda` (U+E048) and
`codaSquare` (U+E049), and MuseScore engraves both markers as words.
Words land in the PDF's text stream, which carries no ink boxes, so no
detector box can ever exist for them. They stay in the class list
because it is frozen and append-only (COCO category ids are positions in
it). The gate therefore subtracts them from its denominator and prints
them on a line of their own:

    [coverage-unreachable] fine EXEMPT (no SMuFL glyph; MuseScore draws
        the word (text stream); see vocabulary.UNREACHABLE)

Deliberately no `n/floor` fraction on that line — an exempt class must
not read as a near-miss. The manifest records `eligible`, `unreachable`
and `below_floor_classes` next to `classes`, so the shrunken denominator
is self-explaining. The exemption list lives in
`generate/vocabulary.py` beside the frozen list, is mirrored by an
`// UNREACHABLE` marker on the matching `detectorTable` rows in
`OMRLabelClassNames.swift`, and `test_vocabulary` fails if the two
disagree — the list cannot grow quietly.

### Do not mix label exports from different classifier versions

`finalize` hashes whatever `*.labels.json` it finds. A glyph classified
as `unknownE522` by one build and as `dynamic` by the next is the *same
ink under two names*: the per-class counts split, the COCO export drops
the `unknown…` half (its category lookup only knows vocabulary names),
and the per-class geometry fingerprints P3c-G4 compares are keyed on the
class name. So whenever `PDFImporter.smuflSemantic` changes, **re-export
labels for every render that will be finalized together** — or generate
into a fresh root. Grafting new renders onto an older run's labels is
the failure this warns about, and nothing detects it.

### P3c-G4 in detail — and the two open questions it settles

MuseScore resolves an unmatched `<musicalSymbolFont>` **silently**: the
render is labeled with the face that was requested and drawn in the
fallback (Bravura), with nothing in any log. The gate therefore reads
**two independent signals** per face, and a face passes only if both
hold.

**Signal 1 — `applied`, glyph geometry.** Neither the class census nor
the label file can name the font (a `noteheadBlack` is a
`noteheadBlack` in every face, and the label schema gives `Glyph` no
font field), so the face-bearing signal the labels *do* carry is
geometry: advance widths and ink boxes are font metrics. They are
normalized by each render's own spatium, paired **per source** so
content is held fixed, and compared only against faces of the **same
engine** (the outlines a face resolves to are a property of the engine
binary). Two faces whose normalized geometry agrees to within `--tol`
are the same outlines, i.e. one fell back. Advance is used alongside the
ink box on purpose, so this keeps discriminating even if bbox recovery
is broken (residual risk 1 below).

**Signal 2 — `font`, the embedded music font's name.** Read straight out
of `score.pdf`: the fonts drawing glyphs whose `/ToUnicode` maps into
the private use area are the music fonts, and their `/BaseFont` name is
compared against the requested face. This is the **positive** signal.
Geometry can only answer "is this different from the faces I compared
against"; the deferred decisions ask "**is this Petaluma?**". The PUA
split matters: `musicalTextFont` is set to "<face> Text", so a face
whose *symbol* font fell back would still show its own name among the
PDF's fonts if names alone were counted. Both spellings of the two
renamed faces are accepted (`MScore`/`Emmentaler`,
`Gootville`/`Gonville`), so this doubles as a check on those
translations.

Each face prints one line:

    [faces][SUMMARY] face=ms4/Leland renders=34 classes=41 self_spread=0.0021 \
        nearest=ms4/Bravura nearest_diff=0.0843 applied=Y font=Y \
        font_names=Leland (34/34) confirmed=Y reason=-

Read `confirmed=` for the verdict; the gate's `applied=N/M` count and
its exit code are over `confirmed`. Reading the columns:

- `applied` — geometry. A collision is reported **symmetrically**: both
  members of the pair show `applied=N` and `reason=collides-with:<face>`
  names the partner, so the reference face flipping to `N` is the same
  finding, not a second one.
- `font` — `Y` every readable render embedded the requested face, `N`
  at least one did not (`font_names` shows what it found instead), `-`
  no PDF was readable, so the check did not run and `confirmed` falls
  back to geometry alone (`reason=font-unavailable`).
- `self_spread` — how much that face's own renders **of one source**
  differ after normalization, i.e. the residual left by the spatium
  normalization. A face counts as `applied` only when `nearest_diff`
  exceeds both `--tol` and this.
- `reason=no-comparison-face` — only one face for that engine, so
  geometry could not judge. The matrix needs at least two.
- `reason=no-renders` — the face is in the run's plan but produced no
  render directory at all: every one of its renders was **quarantined**.
  This is a hard fail, and it is the most likely outcome for a face the
  engine does not support — which is exactly the MS3 probe's hypothesis.
  The expected face set comes from `dataset_plan.json` (falling back to
  the faces named in `quarantine.json`), never from the directories that
  happen to exist, so such a face cannot be scored out of existence.

**SETTLED 2026-08-07: `FACES["ms3"]` now includes both Petaluma and
Leland.** The probe below was run against MuseScore 3.6.2 and gate
P3c-G4 returned `applied=4/4 pass=Y`, both signals agreeing for both
candidates:

    face=ms3/Petaluma renders=36 self_spread=0.0033 nearest=ms3/Bravura \
        nearest_diff=0.4892 applied=Y font=Y \
        font_names=Petaluma,PetalumaText confirmed=Y
    face=ms3/Leland   renders=36 self_spread=0.0014 nearest=ms3/Bravura \
        nearest_diff=0.0556 applied=Y font=Y \
        font_names=Bravura-Text,Leland confirmed=Y

Leland's `Bravura-Text` is its TEXT font falling back, which the
PUA-codepoint split correctly declines to count — the symbol font is
Leland. "MS3 predates Leland", the assumption the face list used to
encode, was simply wrong: Leland shipped in MuseScore 3.6. The MS3 arm
also exported 144 of 144 sources with zero quarantines, which is the
native-MS3-opens-our-schema check below, discharged.

The procedure is kept because it is how any future face candidate gets
decided, and because `--probe-faces` overrides the matrix for one run
without editing the source:

    P=~/Datasets/sheet-music-omr/ms3-face-probe
    Training/.venv/bin/python Training/generate/build_dataset.py generate \
        --root $P --seed $SEED --engines ms3 --per-face 2 --textures 0 \
        --pin-page --probe-faces "ms3=Bravura,MScore,Petaluma,Leland"
    OMR_DATA_ROOT=$P OMR_LABEL_EXPORT=1 swift test
    Training/.venv/bin/python Training/generate/build_dataset.py faces --root $P

**Why the probe differs from a normal run**, in both flags — do not drop
either:

- `--per-face 2` (not 1). At one render per face per source, a face's
  aggregate *is* its single fingerprint, so `self_spread` is identically
  0, the guard branch never fires, and the whole geometry verdict rests
  on `--tol` against a residual nothing has ever measured. Two or more
  variants per face make `self_spread` real.
- `--pin-page`. `style_variants` draws page size as well as spatium, so
  at `--per-face 1` two faces being compared normally differ in page
  size too — different line breaking, a different per-page mix of
  grace/cue-sized glyphs, and therefore a shifted per-class median even
  for identical outlines. Pinning the page makes the face the only
  variable. It does not disturb the spatium draw, so a pinned probe
  stays comparable to a normal run.

Bravura must also stay in the face list: it is the fallback, and
therefore the reference every candidate is measured against. Then read
the candidate's line, **`font=` first**:

- `font=Y … confirmed=Y` → the engine embedded the requested face
  itself. **Add it to `FACES[<engine>]`** in `generate/style_matrix.py`.
- `font=N font_names=Bravura` → it fell back, whatever the geometry
  column says. **Leave the face list alone.**
- `reason=no-renders` → the engine refused the face outright and every
  render was quarantined. **Leave the face list alone**, and read
  `quarantine.json` for the reason.
- `font=-` (no PDF readable) → the probe did not actually test anything;
  fix that before reading the geometry column, because on its own it can
  return `applied=Y` for a fallback.

A probe run also discharges the native-engine schema check: if the arm
exports without quarantines, that engine opened every generated source.
This repo's MS3 reader is stricter than MS4's compat reader, so an MS3
arm is the only thing that proves the MS3 schema we emit is real.

### What to watch for during the pilot

These are known and unfixed under the current constraints; the pilot is
where they first become visible on real MuseScore output.

1. **`bboxMissing` should be near zero, not near the glyph count.** It is
   printed per render by the label export (`[<render_id>][SUMMARY] pages=…
   glyphs=… bboxMissing=… tier1Missing=…`) and is the detector for a
   broken ink-bbox recovery chain. The Type0 `/ToUnicode` path is only
   exercised by real MuseScore output, so this is its first real test. A
   `bboxMissing` comparable to `glyphs` means the chain is broken — every
   detector box would be missing, and the COCO export would silently drop
   those glyphs.
2. **Plausible-but-wrong boxes are invisible to `bboxMissing`.** When many
   CIDs map to one PUA scalar within a single font resource, the label
   exporter keeps the lowest CID, so every glyph sharing that scalar gets
   that CID's outline. The box is present and wrong. Nothing automated
   catches this — open a few rendered pages, draw the boxes, and look.
3. **`<TimeSig><subtype>` (common / cut time) round-trips as a silent
   no-op.** `MSCXDecoder+TimeSignature.swift` reads only `<sigN>`/`<sigD>`,
   so the score-level ground truth parsed from `source.mscx` sees a plain
   4/4 or 2/2. MuseScore still *renders* the C / cut-C glyph, so the
   seam-level label is correct. **A time-signature divergence in
   `OMR_SCORE_EVAL` output on those sources is this, not an OMR error.**
4. **`cov_doublewhole` prints `FAIL-THREW … malformedScore` under
   `OMR_SCORE_EVAL`, and that is expected.** `noteheadDoubleWhole` is in
   the frozen class vocabulary, so the dataset has to draw a breve — but
   `breve` is absent from this package's `NoteDuration(mscxName:)`, so
   `MSCXDecoder+Chord.swift` throws on it and that one `source.mscx`
   cannot serve as score-level ground truth. It is isolated into a
   source of its own precisely so the loss stops there; its seam-level
   labels come from the PDF and are unaffected. Adding `breve`/`long` to
   `NoteDuration` would fix it, but that is a `Sources/` change and this
   branch deliberately makes none.
5. **Lyrics are attached per note, with no melisma**, though the parent
   design describes melismatic attachment. A coverage gap in the
   generators, not a defect in anything under test.
6. **Score-level metrics score `staves.first` only**, so the lower staff
   of a grand-staff part is unscored. Grand-staff renders therefore
   report on roughly half their content.

Two smaller notes on reading the output: a render built from an
`--extra-sources` `.mscz` has a `source.mscz`, and the score-level
harness needs a `source.mscx`, so those renders print
`SKIP-NO-SOURCE-OR-LABELS` in `OMR_SCORE_EVAL` — expected, not a
failure. And `OMR_SCORE_EVAL`'s percentage columns inherit the
real-corpus harness's blind spots (end-truncated parts keep percentages
high, mid-score part loss cascades, measure-count explosions zero out
pitch), so always read `measuresA` / `measuresB` before any percentage.
