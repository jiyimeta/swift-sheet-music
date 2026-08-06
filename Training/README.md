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
| `generate` | `--root --seed [--engines ms4] [--per-face 1] [--textures 20] [--extra-sources DIR...] [--probe-faces ENGINE=Face,Face] [--allow-existing]` | Phase 1: sources → styled score → PDF → raster |
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
`page_<n>.png` and `render.json`, and no `page_<n>.labels.json`. That is
a legal resting state — `status` names it, and every Swift harness skips
a render directory that has no labels rather than failing. Run
`build_dataset.py status --root R` at any point to see which phase you
are in and what to run next.

A directory is a render only once it owns a `render.json`, and
`render.json` is written **last** — after a successful export and a
successful rasterization. A render that failed anywhere is therefore
invisible to the manifest, to `coco`, and to every Swift harness, rather
than half-consumed. For the same reason, `generate` refuses to write
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
| **P0-G1** oracle replay is exact | `OMR_DATA_ROOT=$R OMR_ORACLE_REPLAY=1 swift test 2>&1 \| grep '\[SUMMARY\]'` | every render prints `exact=Y`; the closing line reads `[gate][SUMMARY] P0-G1 exact=N/N` with both numbers equal |
| **P0-G2** run twice, byte-identical | rerun any harness command into `…-run2.txt` and `diff` it against run 1; for the label export also `find $R -name '*.labels.json' \| sort \| xargs shasum -a 256` after each run and `diff` those | empty `diff` both times |
| **P0-G3** back-end ceiling measured | `OMR_DATA_ROOT=$R OMR_SCORE_EVAL=1 swift test 2>&1 \| grep '\[SUMMARY\]' > ceiling.tsv` and `OMR_DATA_ROOT=$R OMR_SEAM_EVAL=1 swift test 2>&1 \| grep '\[SUMMARY\]' > seam.tsv` | not a threshold — the recorded rows **are** the ceiling. Read `measuresA` / `measuresB` before any percentage (see blind spots below) |
| **P0-G4** vector path untouched | **maintainer step, run in the MAIN checkout, not in this worktree** — the untracked spike harnesses and the copyrighted corpus live there. Curated 6 + real corpus must stay byte-identical | expected trivially (this work changed nothing under `Sources/`); still run it |
| **P3c-G1** same seed ⇒ byte-identical | generate a second root with the **same seed**, run steps 2–3 over it, then `Training/.venv/bin/python Training/generate/build_dataset.py compare $R ${R}b` | `[compare][SUMMARY] identical=Y` (exit 0). Labels + manifest only; images are excluded by design |
| **P3c-G2** export success ≥ 99% | read `finalize`'s output (or `manifest.json` → `gates.P3c-G2`) | `[gate][SUMMARY] P3c-G2 export_success=… pass=Y` |
| **P3c-G3** per-class coverage floor | same run; every shortfall prints a `[coverage-below-floor] <class> n/floor` line | `[gate][SUMMARY] P3c-G3 below_floor=0/64 pass=Y`. A first pilot will not pass this — the report tells you which classes to generate more of |
| **P3c-G4** face actually applied | `Training/.venv/bin/python Training/generate/build_dataset.py faces --root $R` | `[gate][SUMMARY] P3c-G4 applied=N/N pass=Y` (exit 0) |

**Frozen eval set** (spec §6.5), after the manifest exists — degrades
every page once, with a recorded seed, into `$R/eval_frozen/`:

    Training/.venv/bin/python Training/generate/build_dataset.py freeze \
        --root $R --seed $SEED

**COCO convenience export** (the canonical label JSON stays
authoritative — COCO cannot carry paths, curves, origins, or advances):

    Training/.venv/bin/python Training/generate/build_dataset.py coco --root $R

### P3c-G4 in detail — and the two open questions it settles

MuseScore resolves an unmatched `<musicalSymbolFont>` **silently**: the
render is labeled with the face that was requested and drawn in the
fallback (Bravura), with nothing in any log. Neither the class census
nor the label file can name the font — a `noteheadBlack` is a
`noteheadBlack` in every face — so the gate uses the one face-bearing
signal the labels do carry: glyph **geometry**. Advance widths and ink
boxes are font metrics, normalized here by each render's own spatium,
aggregated per face, and compared only against faces of the **same
engine** (the outlines a face resolves to are a property of the engine
binary). Two faces whose normalized geometry agrees to within `--tol`
are the same outlines, i.e. one of them fell back. Advance is used
alongside the ink box on purpose, so the gate keeps discriminating even
if bbox recovery is broken (residual risk 1 below).

Each face prints one line:

    [faces][SUMMARY] face=ms4/Leland renders=34 classes=41 self_spread=0.0021 \
        nearest=ms4/Bravura nearest_diff=0.0843 applied=Y reason=-

`applied=Y` means confirmed distinct from every other face of that
engine. A collision is reported **symmetrically** — both members of the
pair show `applied=N`, and `reason=collides-with:<face>` names the
partner. `self_spread` is how much that face's own renders vary; a face
only counts as applied when `nearest_diff` exceeds both `--tol` and its
own spread. `reason=no-comparison-face` means the dataset had only one
face for that engine, so the gate could not judge — the matrix needs at
least two.

On the MS4 arm this also checks the two-name translations
`style_matrix` performs (`MScore`→`Emmentaler`, `Gootville`→`Gonville`):
if either were wrong, that face would collide with `ms4/Bravura`.

**Open question: should `FACES["ms3"]` include Petaluma? Leland?**
Evidence says MuseScore 3.6.2 almost certainly offers Petaluma, but
adding it on that basis alone would be strictly worse than omitting it —
renders labeled `petaluma` and drawn in Bravura are poison for a
font-diversity dataset. Settle it by measuring, with no source edit
(`--probe-faces` overrides the matrix for one run and restores it):

    P=~/Datasets/sheet-music-omr/ms3-face-probe
    Training/.venv/bin/python Training/generate/build_dataset.py generate \
        --root $P --seed $SEED --engines ms3 --per-face 1 --textures 0 \
        --probe-faces "ms3=Bravura,MScore,Petaluma,Leland"
    OMR_DATA_ROOT=$P OMR_LABEL_EXPORT=1 swift test
    Training/.venv/bin/python Training/generate/build_dataset.py faces --root $P

Bravura must stay in that list: it is the fallback, and therefore the
reference every candidate is measured against. Then read exactly two
lines of the output:

- `face=ms3/Petaluma … applied=Y reason=-` → MS3 renders Petaluma as its
  own outlines. **Add `"Petaluma"` to `FACES["ms3"]`** in
  `generate/style_matrix.py`.
- `face=ms3/Petaluma … applied=N reason=collides-with:ms3/Bravura` → it
  fell back. **Leave `FACES["ms3"]` alone.**

The `face=ms3/Leland …` line answers the Leland question the same way.
(MS3 predates Leland, so `applied=N` is the expected outcome there —
which is why the probe is worth running rather than assuming either
answer.) While the probe dataset exists, also hand-open one of its
generated `.mscx` files in native MuseScore 3: this repo's MS3 reader is
stricter than MS4's compat reader, and only native MS3 proves the
generated schema opens.

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
