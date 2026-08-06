# Training — synthetic OMR dataset generation (P3c)

Scripts that generate the synthetic training/eval datasets for the raster
OMR program (see docs/superpowers/specs/2026-08-06-omr-raster-foundation-design.md).
Datasets live OUTSIDE the repo at `~/Datasets/sheet-music-omr/<version>/`
(override with `OMR_DATA_ROOT`). Nothing dataset-sized or copyrighted is
ever committed; admissible sources are procedurally generated scores,
public-domain scores, and the repository owner's own originals only.

## Setup

    python3 -m venv Training/.venv
    Training/.venv/bin/pip install -r Training/requirements.txt

## Tests

    Training/.venv/bin/pytest Training/tests -q

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
| `generate` | `--root --seed [--engines ms4] [--per-face 1] [--textures 20] [--extra-sources DIR...] [--probe-faces ENGINE=Face,Face] [--pin-page] [--allow-existing]` | Phase 1: sources → styled score → PDF → raster |
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

    R=~/Datasets/sheet-music-omr/v1
    SEED=20260806

**1. Generate** (needs MuseScore; add the owner's originals at run time —
never a tracked path, and never a copyrighted corpus):

    Training/.venv/bin/python Training/generate/build_dataset.py generate \
        --root $R --seed $SEED --engines ms4 --per-face 2 --textures 100 \
        --extra-sources ~/Desktop/free_score

**2. Label export** (Swift; forced Tier 1). This is the phase boundary:

    OMR_DATA_ROOT=$R OMR_LABEL_EXPORT=1 swift test 2>&1 \
        | grep '\[SUMMARY\]' | sort > /tmp/omr-export-run1.txt

**3. Finalize** — writes the manifest and scores two gates:

    Training/.venv/bin/python Training/generate/build_dataset.py finalize \
        --root $R --seed $SEED

### Gate → command

| Gate | Command | Pass looks like |
|---|---|---|
| **P0-G1** oracle replay is exact | `OMR_DATA_ROOT=$R OMR_ORACLE_REPLAY=1 swift test 2>&1 \| grep '\[SUMMARY\]'` | every render prints `exact=Y`; the closing line reads `[gate][SUMMARY] P0-G1 exact=N/N inexact=0 skipped=0 failed=0 pass=Y` **and `N > 0`**. Read `pass=`, not the two numbers: the denominator counts every render directory visited, so a skip (label export never ran for it) or a throw (unopenable PDF) is a miss, and an empty sweep is `exact=0/0 … pass=N`, never a pass. `swift test` itself fails when `pass=N` |
| **P0-G2** run twice, byte-identical | rerun any harness command into `…-run2.txt` and `diff` it against run 1; for the label export also `find $R -name '*.labels.json' \| sort \| xargs shasum -a 256` after each run and `diff` those | empty `diff` both times |
| **P0-G3** back-end ceiling measured | `OMR_DATA_ROOT=$R OMR_SCORE_EVAL=1 swift test 2>&1 \| grep '\[SUMMARY\]' > ceiling.tsv` and `OMR_DATA_ROOT=$R OMR_SEAM_EVAL=1 swift test 2>&1 \| grep '\[SUMMARY\]' > seam.tsv` | not a threshold — the recorded rows **are** the ceiling. Read `measuresA` / `measuresB` before any percentage (see blind spots below) |
| **P0-G4** vector path untouched | **maintainer step, run in the MAIN checkout, not in this worktree** — the untracked spike harnesses and the copyrighted corpus live there. Curated 6 + real corpus must stay byte-identical | expected trivially (this work changed nothing under `Sources/`); still run it |
| **P3c-G1** same seed ⇒ byte-identical | generate a second root with the **same seed**, run steps 2–3 over it, then `Training/.venv/bin/python Training/generate/build_dataset.py compare $R ${R}b` | `[compare][SUMMARY] identical=Y` (exit 0). Labels + manifest only; images are excluded by design |
| **P3c-G2** export success ≥ 99% | read `finalize`'s output (or `manifest.json` → `gates.P3c-G2`) | `[gate][SUMMARY] P3c-G2 export_success=… denominator=plan … missing=0 pass=Y`. `missing>0` means renders the plan drove that are neither exported nor quarantined — an interrupted `generate`, so rerun it before believing anything else |
| **P3c-G3** per-class coverage floor | same run; every shortfall prints a `[coverage-below-floor] <class> n/floor` line | `[gate][SUMMARY] P3c-G3 below_floor=0/64 pass=Y`. A first pilot will not pass this — the report tells you which classes to generate more of |
| **P3c-G4** face actually applied | `Training/.venv/bin/python Training/generate/build_dataset.py faces --root $R` | `[gate][SUMMARY] P3c-G4 applied=N/N pass=Y` (exit 0). The count is over `confirmed=`, i.e. geometry **and** embedded font name together — see below |

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

**Open question: should `FACES["ms3"]` include Petaluma? Leland?**
Evidence says MuseScore 3.6.2 almost certainly offers Petaluma, but
adding it on that basis alone would be strictly worse than omitting it —
renders labeled `petaluma` and drawn in Bravura are poison for a
font-diversity dataset. Settle it by measuring, with no source edit
(`--probe-faces` overrides the matrix for one run and restores it):

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
the `face=ms3/Petaluma` line, **`font=` first**:

- `font=Y … confirmed=Y` → MS3 embedded Petaluma itself. **Add
  `"Petaluma"` to `FACES["ms3"]`** in `generate/style_matrix.py`.
- `font=N font_names=Bravura` → it fell back, whatever the geometry
  column says. **Leave `FACES["ms3"]` alone.**
- `reason=no-renders` → MS3 refused the face outright and every render
  was quarantined. **Leave `FACES["ms3"]` alone**, and read
  `quarantine.json` for the reason.
- `font=-` (no PDF readable) → the probe did not actually test anything;
  fix that before reading the geometry column, because on its own it can
  return `applied=Y` for a fallback.

The `face=ms3/Leland …` line answers the Leland question the same way.
(MS3 predates Leland, so a fallback or a quarantine is the expected
outcome there — which is why the probe is worth running rather than
assuming either answer.) While the probe dataset exists, also hand-open
one of its generated `.mscx` files in native MuseScore 3: this repo's
MS3 reader is stricter than MS4's compat reader, and only native MS3
proves the generated schema opens.

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
4. **Lyrics are attached per note, with no melisma**, though the parent
   design describes melismatic attachment. A coverage gap in the
   generators, not a defect in anything under test.
5. **Score-level metrics score `staves.first` only**, so the lower staff
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
