# OMR — Open Work

What is left in the optical-music-recognition path, why each item is
open, and what has already been measured about it. Kept in the repository
rather than in a plan under `docs/superpowers/` (which is gitignored) so
it survives the worktree it was written in.

Companion documents:

- `Training/README.md` — the dataset/training pipeline, every frozen
  number, and the gates. The per-round measurements live there; this file
  only names what is still open.
- `docs/development/` — how to run things.

**Status, 2026-09-03.** The raster front-end reads scanned PDFs end to
end (`PDFImporter.parse` with `PDFImportOptions.omrTileClassifier`), the
detector ships as a compiled Core ML model in `SheetMusicOMRModel`, and
against 657 real `.mscz` scores the raster path scores pitch p50 0.9406 /
duration p50 0.9188 with the vector path byte-identical. The vector
ceiling on the same corpus is 0.9920 / 0.9948, so **the raster path costs
about 5 points of pitch and 7.5 of duration**, and that gap is what the
items below are about.

## How to measure anything here

Do not build a new instrument before checking these. Every one of them
was written for a question that turned out to need it.

| Instrument | Answers |
|---|---|
| `MSCZGroundTruthEvalHarness` (`OMR_MSCZ_EVAL=1`) | the whole corpus, both front-ends, per file. `OMR_MSCZ_LIMIT` bounds it, `OMR_MSCZ_ONLY` selects one score, `OMR_MSCZ_DIVERGENCE=1` dumps where two readings stop agreeing |
| `OMR_MSCZ_CLEF_PROBE=1` | `[mscz-clefprobe]` / `[mscz-clefcand]` — every raster candidate near a vector clef, with its heatmap score; and `[mscz-clefextra]`, every raster clef with no vector clef near it |
| `OMR_MSCZ_CLEF_CAPTURE=1` | `[mscz-clefcap]` / `[mscz-inforce]` — how many clefs reach a measure, and which clef ends up in force per staff |
| `OMR_MSCZ_CENSUS=1` | per-class glyph counts, both front-ends, same document |
| `OMR_DECODE_THRESHOLD` / `_TOP_K` / `_NMS_SP` | the three decode constants, without re-exporting a model |
| `OMR_MODEL_ROOT` | which exported model runs. **Every corpus log opens with `[mscz] model=… checkpoint=…`; read it before believing a comparison** |
| `Training/probes/clef_table.py` | a candidate dump → the per-class exact/sibling/other/none table, and decode rules priced offline |
| `Training/probes/clef_split_hist.py` | one class's confidence split against its plain sibling |
| `Training/probes/corpus_ab.py` | two corpus sweeps → paired per-file pitch/duration deltas |
| `OMR_HYBRID_MODE` (`truthStaffLines` / `truthVerticals` / `truthBeams` / `truthPaths`) | hand one primitive back to the oracle; the recovered score is that primitive's share of the loss |

Rules that cost this program a round each: compare only sweeps taken with
**one binary**; decide nothing about the corpus on fewer than 200 files
(a 60-file sample reversed sign at 200); and a hypothesis counts only
once a counterfactual has counted it (the running record is 1 for 9).

## Open — importer

### A false clef inside a measure poisons every note after it

A clef the detector proposes where none is engraved changes the clef in
force for the rest of that staff. Over 200 corpus scores the shipped
model puts 50 such clefs above the detection threshold (the previous
model, 75); most sit where `readClef` never looks, but the ones that land
in the courtesy-clef position cost whole documents — at the 200-file
scale, two of the largest losses were exactly one false `clefF` each
(`Start over!` −21, `366日` −15).

There is no importer-side guard. `[mscz-clefextra]` counts them.
Candidate shapes: require a clef inside a measure to agree with the
staff's established clef family unless it repeats across systems (the
per-slot consensus pass already reasons this way for system-initial
clefs); or weight a clef by the detector's score, which the importer
currently never sees.

### The same document reads as a different number of parts

`虜_acoustic.mscz` reads as 7 parts under one detector and 8 under
another, with identical clefs in force. Part count decides the harness's
alignment and the score's whole structure, so a one-part difference moves
a file's pitch by tens of points in either direction — three of the four
largest losses AND the three largest wins of the last round are this
mechanism, not recognition quality.

Nothing has diagnosed it. It is the largest single lever visible in the
corpus numbers, and it is upstream of recognition: the structure pass
(`detectStaves` → `ensembleStaffCount` → `layoutSystems`) decides part
and staff grouping before any glyph is read. Start with
`OMR_MSCZ_DIVERGENCE=1`, which prints both sides' part/staff shape.

### Some documents collapse to a fraction of their measures

`original/アイデア#0043.mscz` is read as 24–30 measures against a truth of
200 — by every model tried. A per-file scan for `measuresB` far below
`measuresA` in any corpus sweep finds the population; nobody has run it.

### The initial time signature is dropped

A score's opening time signature does not survive PDF import: the
emitters skip a value that equals the default in the first measure. Known
and untouched; it is an importer defect, not a raster one, so it is
listed here only because a scanned page has no other way to recover it.

## Open — detector

### `clefG8vb` is sometimes read as `clefG15mb`

The supplement that taught octave clefs their real-score context also had
to choose how often to engrave each one. A uniform draw over the nine
non-plain clefs made `clefG15mb` — a clef real scores almost never carry —
as plausible as the tenor clef, and 155 of 7556 real `clefG8vb` were read
as `clefG15mb`. Narrowing the prior (plain 50% / common octave and C 40% /
`15ma`+`15mb` 10%) took that to 106.

**Priced: 59 files touched, net +42pt, losses −37pt.** Taking it to zero
means one more training round for ~37 points out of the 610 the round
gained, so it was left. The next step, if it is ever worth it, is a
supplement with no `15ma`/`15mb` at all — those classes are already
taught by `cov_clef_*`, and the supplement's job is context, not
coverage.

### `rest32nd` is not recognized

Recall 0.6% on the synthetic eval set — 1 true positive against 159
misses, while `rest16th` collects 122 false ones on the same pages. The
held-out set contains none of the class at all, so it cannot even see the
defect. It appears only in `cov_flags` / `cov_durations`, so no
real-corpus weight either — which is why it has never been worth a round. Fixing it is a data question, the
same shape as the clef one: the class exists in the vocabulary and in the
coverage family, but never in realistic context.

### The four decode constants are unmeasured

Every seam summary still prints `decodeDefaultsMeasured=false`. Threshold
0.30, top-K 300, NMS radius 0.5 sp and the tile geometry were chosen, not
swept end to end. A partial sweep exists: on the synthetic set 0.20–0.35
moves pitch and duration by under a point while 0.40 costs 2.7 points of
duration, and a corpus-wide threshold change was measured and rejected
(200 files, pitch net −27pt). The
remaining constants are open, and cheap — `OMR_DECODE_*` needs no
re-export.

### The synthetic seam and the real corpus disagree about progress

The shipped model is slightly worse on the synthetic held-out seam
(clean val recall 0.9969 against 0.9974, origin 0.0348 against 0.0331)
and clearly better on real scores. The synthetic set has been the primary
metric for three rounds; it is now the weaker signal, and a round that
optimises it may cost real documents. Worth deciding deliberately before
the next round rather than by habit.

## Open — platform

### Android has no OMR

The detector runs through the public `OMRTileClassifier` protocol, which
`SheetMusicOMRModel` implements with Core ML; the `.mlmodelc` in the
bundle is Apple-only by construction. Everything above that protocol —
tiling, decode, merge, assembly — is plain Swift in `SheetMusicPDF`, and
the exporter already writes `model.onnx` beside the Core ML model, so the
missing piece is an ONNX-Runtime implementation of one method
(`run(tile:) -> OMRHeadOutputs`) plus packaging.

Two things are unverified and would have to be checked first: whether
that Swift compiles for Android today (the raster entry points are
excluded there, and `SWIFT_SHEET_MUSIC_ANDROID=1 swift build` already
fails on `main` for unrelated reasons), and how a page becomes pixels at
all on Android — `PDFPageRasterizer` is CoreGraphics.

### Real scans have never been measured

Every number in this document and in `Training/README.md` comes from
MuseScore renders — synthetic pages, or real `.mscz` scores rendered by
MuseScore and re-wrapped as images. **No photograph and no flatbed scan
has been through this pipeline.** The degradation profile
(`Training/generate/profiles/scanner.toml`) is a model of a scan, not a
scan, and the one measurement that bounded it (photometric augmentation
transferring to unseen corruption) was itself synthetic.

This is the largest unquantified risk in the raster path.

## Closed, so nobody re-opens them

- **Resolution.** More pixels do not fix a split between a clef and its
  octave sibling; at 400 and 600 dpi the mass moves toward the *plain*
  sibling. Measured at four scan resolutions.
- **The detection threshold as a clef fix.** Both directions lose: high
  drops true octave clefs, low lets a false plain clef displace a true
  `clefG8vb`. 200-file counterfactual, pitch net −27pt.
- **Classical CV.** Staff lines, verticals and beams were driven to the
  oracle-replay ceiling over three rounds; the remaining bisect headroom
  is inside pathological fixtures.
- **Percussion staves losing 86% of their notes.** A misdiagnosis: the
  fixtures place noteheads 3.5–8.5 spaces below the staff, and the
  capture band refuses them by design.
- **Augmentation as a substitute for context data.** The augmented-only
  model reads 213 of 475 `clefF8va` where the context-trained one reads
  475, and loses pitch against the previous model.
