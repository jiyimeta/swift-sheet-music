# PDF Import — Real-Corpus Accuracy Improvement (Design & Cycle)

**Date:** 2026-07-10
**Branch/worktree:** `worktree-pdf-import-real-corpus` (`.claude/worktrees/pdf-import-real-corpus`), branched from local `main` HEAD `6eb87ac8` (includes the S8 tie/duration work not yet on `origin/main`).
**Status:** approved to execute (proceeding autonomously; Fable = fix, Opus = per-round verification).

This design generalizes the S5–S8 curated-corpus improvement cycle (6 scores) to
the **real user corpus** of 130 `.mscz` + 4 `.mscx` MuseScore sources under
`~/Desktop/pdf_test/real/`. The investigation and cycle methodology were produced
by a Fable subagent and independently verified against the raw logs by Opus.

## Goal

Raise PDF-import accuracy across the real corpus **with zero regression** on both
(a) the 6 curated anchors and (b) the real-corpus "already-good" set, using the
proven round-based cycle. Success = `median pitchedOnly ≥ 97 ∧ p10(pitchedOnly) ≥
90 ∧ no BUG cluster with ≥ 3 unique pieces remaining`.

## Corpus & tooling

- **Ground truth:** `~/Desktop/pdf_test/real/` (130 `.mscz` + 4 `.mscx`;
  ~111 MuseScore-3 format, ~23 MuseScore-4, 1 MuseScore-2).
- **PDF inputs:** exported with the native **`mscore` CLI** — MuseScore 3.app for
  v2/v3 sources (Leland font), MuseScore 4.app for v4 — into
  `~/Desktop/pdf_test/real_pdfs/`. Script:
  `scratchpad/export-real-corpus.sh` (idempotent, format-routed; success judged by
  the written PDF, since MS4's crashpad can make a successful export exit non-zero).
  **Coverage: 132 / 133 names.** Only `Chandelier（歌詞スキャット仮入れ）提案`
  cannot be exported (MuseScore 4 itself `Abort trap: 6` on that file).
- **Harness:** `Tests/SheetMusicTests/PDFCorpusGroundTruthSpikeTests.swift`.
  `measureCorpusDiff()` scores the curated 6; the new `measureRealCorpusDiff()`
  (gated by `PDF_REAL_CORPUS=1`; `PDF_REAL_ONLY=<name>` / `PDF_REAL_LIMIT=<n>`
  knobs) scores the real corpus, emitting the same machine-greppable `[SUMMARY]`
  rows. `measureOne` was parameterized with `msczDir`/`pdfDir`/`msczExt`; no
  scoring logic duplicated.

## Metric glossary

Score A (mscz/mscx) is paired with Score B (PDF re-import) **by part index** up to
`min(partsA, partsB)`, **first staff only**, **by measure index** up to
`min(measuresA, measuresB)`. Anything past either `min` is silently unscored.

- **pitch%** — positional match of per-measure first-note MIDI-pitch sequences
  (voices concatenated in order); denom `max(|pa|,|pb|)`; percussion included.
- **pitchedOnly%** — pitch% but skipping any part whose B staff carries a
  PERCUSSION clef (drum "pitch" is a GM key, not pitch-meaningful).
- **pitchSet%** — per-measure multiset intersection (order-insensitive) — isolates
  "content right, order wrong" from genuine content loss.
- **dur%** — positional `NoteDuration` equality (type + dots + tuplet fraction).
- **tieRecall** — per-chord "any note tied" booleans, positionally aligned;
  `tp/(tp+fn)` vs A's tied chords.
- **lyrRecall** — verse-0 lyric-token multiset recall over measures with lyrics.

**Blind spots (must keep in mind when reading numbers):** (1) a whole part lost/hidden
at the END keeps every % high while a part goes unscored (ファンファーレ:
4376→2219 notes yet po=99%); (2) a part lost in the MIDDLE compares wrong
instruments downstream (catastrophic %); (3) a measure-count explosion cascades
into pitch 0% (mimicopy_もしも 100→287 measures).

## Curated regression baseline (must never regress)

Captured 2026-07-10; these 6 rows are the zero-regression anchors:

```
[ギブス]       measuresA/B=91/91   notes=1608/1608  pitch=100 pitchedOnly=100 dur=100 tie=100
[君とParadiso]  measuresA/B=112/112 notes=3044/3044  pitch=99  pitchedOnly=100 dur=98  tie=99
[群青日和]      measuresA/B=121/121 notes=2976/2976  pitch=99  pitchedOnly=100 dur=99  tie=100
[地球儀]        measuresA/B=62/62   notes=1255/1254  pitch=98  pitchedOnly=99  dur=96  tie=99
[カゲロウ]      measuresA/B=192/192 notes=6155/6152  pitch=98  pitchedOnly=99  dur=99  tie=99
[ロビンソン]    measuresA/B=89/89   notes=1142/1142  pitch=100 pitchedOnly=100 dur=99  tie=99
```

## Real-corpus baseline (round 0, 2026-07-10)

127 scored / 2 hard-crash / 0 threw / 1 missing-PDF / 3 `.mscx` ground-truth
parse-fail (harness gap).

| metric | median | mean | below 90% | below 50% |
|---|---|---|---|---|
| pitch% | 90 | 67.2 | 63 | 41 |
| **pitchedOnly%** | **97** | 70.4 | **55** | 38 |
| dur% | 94 | 71.7 | 56 | 37 |
| tieRecall | 97 | 79.6 | 52 | 21 |

`measuresA == measuresB`: 78/127. **"Already-good" set (po ≥ 95 ∧ dur ≥ 90): 60
scores** — the real-corpus zero-regression guard.

**Verified reframing (spot-checked against raw logs):** the low *mean* is not
diffuse importer failure — the distribution is bimodal (≥95 or ≤50). The core
importer works on the real corpus (60 already-good, median po 97); the damage is
concentrated in a small number of *structural* causes (part/measure segmentation)
that are fully recoverable from the page. The curated 6 were all full-ensemble,
no-hidden-staff, constant-system-shape scores — exactly the layouts the real
corpus's failure modes never exercised.

## Gap clusters — bugs vs ceilings

- **C1. System/part structure collapse — ~43 rows (~36 unique) — BUG, top priority.**
  PART-EXPLODE (B 2–4× A parts, e.g. 革命道中 6→12 with notes fully recovered yet
  po=5%; 奪い返して 4→16 po=1%; つよがるガール_bass 1→10), SEG-OVER/UNDER-SPLIT
  (mimicopy_もしも 100→287 po=0%; the exact-×2 signature Melody 120→240,
  Super_Ball 66→132), PART-LOSS-SHIFT (365日 8→6 po=39%). Root causes in
  `PDFImporter+Structure/Layout/AssembleParts`: MuseScore **hide-empty-staves**
  (per-system varying staff shapes create spurious part slots), single-staff /
  no-spine systems merging or stacking sequentially. All info is printed.
- **C2. Whole-part content loss — 9 scores — BUG.** One part fully dropped while
  the rest scores ≥90 (ファンファーレ 4376→2219 notes, po=99%). Hypothesis:
  1-line/3-line percussion staves invisible to the 5-line `detectStaves`; the S6
  percussion pipeline never sees them. Recoverable.
- **C3. Hidden-empty-part metric artifact — 22 scores — HARNESS FIX.** A carries an
  empty hidden part; B is correct (notesA==notesB, po≥95; あの夏に咲け,
  鼓動PARADE). Index-based part pairing merely got lucky the empty part sorts last;
  when it doesn't, it becomes a C1 catastrophic row. Fix in the harness (align by
  content / drop zero-note A-parts; report `unmatched-A-part-with-N-notes`
  separately so C2 stays visible). **Not an importer bug.**
- **C4. Pitch-decode residuals — 14 scores — BUG.** Systematic +12 octave
  (Magnetic_Short po=73/dur=100, チャンカパーナ 54/99 — clef-octave "8" glyph not
  attached), part-slot swaps (Groovynight ×3), key-signature misreads. All printed.
- **C5. Hard crash on import — 2 scores (1 family) — BUG (cheap).**
  `革命道中_kiichi1/2`: `Fraction` precondition "denominator must be positive"
  inside `PDFImporter.parse` — a mis-decoded time signature (denom 0). A library
  must not `fatalError` on hostile input; validate + diagnostic fallback.
- **C6. Duration/tie tail — ~15 scores — BUG + known ceilings.** dur 79–94 / tie
  80–90 on otherwise-good scores; the S8 micro-fix regime (flag/beam/tuplet
  geometry).

**Ceilings (do NOT spend rounds):** lyric text recall beyond ~90–95; drum MIDI
pitch behind X/slash noteheads & GM-slot collisions (S8-proven); chord-symbol/fret
text & non-verse-0 lyrics (out of scope); the 1 MS4-CLI-uncrashable PDF.
(Drum *staff recognition* is C2, **not** a ceiling.)

## Cycle methodology

**Round = one cluster, one bounded mechanism-fix, full re-measure (~8 min).**
Diagnose on 2–3 representatives with the existing gated probes (taught a
`PDF_PROBE_DIR` override in R0). Fix the *mechanism* stated in engraving
invariants ("MuseScore draws X"), spatium-relative — never "works on score Y".

**Three gates, in order, every round:**
- **Gate A (curated 6):** the 6 `[SUMMARY]` rows must not regress on any numeric
  field; ギブス stays 100/100/100. Byte-diff.
- **Gate B (real-good 60):** no score's pitchedOnly/dur/tieRecall may drop (any −1
  integer point is a real regression → investigate before proceeding).
- **Gate C (target cluster):** the majority of the cluster's members must move
  materially; if only the diagnosed representative moved, the fix is overfit →
  revert or generalize.

**Snapshot:** each round commits its full `[SUMMARY]` TSV (`baselines/round-N.tsv`)
so rounds diff mechanically.

**Overfitting control:** fix clusters (diagnose ≥2, verify whole cluster);
near-duplicate families (奪い返して×3, Groovynight×3, W●RK×2, 革命道中×4,
ナウシカ×2) count as ONE piece; a **12-score stratified holdout** (4 good/4 mid/4
bad, picked once in R0) is never used for diagnosis, only measured — divergent
holdout deltas mean the fix memorized the corpus.

**Round order = damage × tractability.** Cheap, meaning-changing work first
(crash robustness + harness hygiene), then the big structural cluster, then part
recovery, pitch decode, and the dur/tie tail.

## Prioritized plan

| round | target | expected |
|---|---|---|
| **R0** harness hygiene (test file only) | C3 content-based part alignment + `unmatched-A-part` metric; parse `.mscx` via `MSCXParser`; `PDF_PROBE_DIR` for probes; `baselines/` snapshot; pick 12-score holdout | 22 artifact rows reclassify; +3 scorable; every later number trustworthy |
| **R1** crash robustness | C5 validate decoded time-sig / computed Fraction denominators; throw + diagnostic, no precondition | crashes 2→0; batch always completes |
| **R2** system/part structure (the big one; 2–3 sub-rounds) | C1 (a) per-system part-slot identity under hide-empty-staves; (b) single-/few-staff system clustering; (c) stop sequential stacking (×2-measure signature) | ~30–35 scores ≤50→≥90 po; measures-exact 78→110+; mean po +15–20 |
| **R3** percussion / 1-line staff recovery | C2 detect 1-/3-line percussion staves in `detectStaves`, route to S6 pipeline | thousands of notes recovered; PART-LOSS-CONTENT 9→~0 |
| **R4** pitch decode residuals | C4 clef-octave "8" attachment (±12), key reading, slot-swap leftovers | 14 scores 49–85 → ≥95 |
| **R5** duration/tie tail | C6 (S8 regime) flag/beam/tuplet geometry; tie funnel | dur below-90 56→<10; tie median 97→99 |
| **R6** re-baseline & freeze | full corpus + curated 6; commit final baseline; update auto-memory | stopping-criterion check |

## Round-0 baseline record

The full per-score table lists the user's real (partly copyrighted) arrangement
filenames, so — consistent with this repo's "don't commit copyrighted material"
posture — it is **not committed**. Round baselines live in the session scratchpad
(`pdf-real-corpus-proposal.md` §7 appendix, `real_baseline.log`, `real_table.tsv`,
`clusters_final.txt`, and `baselines/round-N.tsv` snapshots) as the mechanical diff
base for every round. Only the aggregate stats and representative names (above) are
committed. The final frozen baseline committed in R6 is aggregate-only.

## Execution results (2026-07-10)

The cycle ran R0 → R2c (8 rounds). Every round held the three gates (curated 6
byte-identical, real already-good set no-regression, target cluster moves) and
preserved determinism. Commits are on `worktree-pdf-import-real-corpus` (not
merged/pushed). PDFs were exported with the native `mscore` CLI (MS3/MS4
format-routed), 132/133 names covered.

### Metric progression (132 scored real-corpus scores)

| stage | already-good (po≥95∧dur≥90) | median po | mean po | below-90 po | crashes |
|---|---|---|---|---|---|
| baseline (R0-corrected) | 60 | 98 | 72 | 53 | 2 |
| R2b part-structure | 95 | 99 | 92 | 21 | 0 |
| R3 hidden-part scoring | 96 | 99 | 92.6 | 20 | 0 |
| R4 octave + R4b key | 106 | 99 | 94.3 | 12 | 0 |
| R2c grand-staff coupling (final) | **107** | **99** | **95.2** | **12** | **0** |

Curated 6 byte-identical at every round. Final: dur median 98 / mean 93.2, tie
median 99 / mean 96.7; true importer content loss (`partLoss>0`) on **1** score.

### Two corrections to the original plan
1. **R2a (determinism) — unplanned, foundational.** The importer's structure
   output was per-process nondeterministic (hash-seed-dependent Dictionary/Set
   iteration): the same PDF scored 96% or 9% across runs. Fixed by deterministic
   iteration order — nothing measurement-gated could be trusted until then.
2. **C2 was a ground-truth artifact, not an importer bug.** The plan hypothesized
   whole parts lost to 1-line percussion staves invisible to `detectStaves`.
   Verified diagnosis: the "lost" parts are `<show>0</show>` — marked invisible in
   the source, never engraved in the PDF (ファンファーレ Perc 2157 notes, 365日
   Lead[0] 594 notes). The importer imports 100% of printed content. Fixed in the
   harness (R3) by excluding hidden A-parts from scoring. Exactly one genuine
   reduced-line-staff loss exists corpus-wide (The_Feels, 23 notes), deferred.

### Round ledger (commits)
- R0 harness hygiene (content part-alignment, `.mscx`, probe dir, holdout) — spec `013a0b76`.
- R1 crash robustness ("90" → `Fraction(9,0)` guard) + R2a determinism — `9dee19ec`.
- R2b part-structure (system-barline clustering, `SystemsSpanning.swift`) — `7df2fbfd`.
- R3 hidden-part scoring (harness, untracked — no Sources change).
- R4 E065 ottava-clef octave by ensemble voicing — `a8451f79`.
- R4b naturals-only key-cancellation to C — `00fb6007`.
- R2c grand-staff coupling by brace glyph U+E000 (separation invariant vs square
  brackets), extracted to `PDFImporter+Coupling.swift` — this round.

### Remaining below-90 tail (12) — heterogeneous / near-ceiling
No single mechanism affects ≥3 pieces with a clean shared root; further gains are
per-score, each a distinct root:
- **Multi-measure-rest H-bars** — `mimicopy_ラストオーダー`/`mimicopy_ベーコンエピ`
  collapse 100 measures to ~17–18 because a "N-bar" H-rest (e.g. "83"/"84") is read
  as one measure; needs an expand-mm-rest mechanism (distinct from R2c coupling).
- **Grand-staff internal alignment** — `疑事無功_piano` (coupling now correct, one
  part; but the two braced staves' voices/measures don't interleave, po=7).
- Per-score singletons: `Girls_Be_Free 4` (part-count 6→5), `Join_Us_ito`,
  `君がいないから+2`, `つよがるガール_bass` (single-staff), `BGM_20250522`,
  `mimicopy_恵比寿`, `idea20241203`, `あみまんじゅうの歌`.

### Follow-ups (not done this session)
- **Multi-measure-rest expansion**: read an "N" H-bar rest as N measures (fixes the
  mimicopy_ラストオーダー/ベーコンエピ 100→17 collapse).
- **Grand-staff internal alignment**: brace coupling is correct now (R2c), but the
  two braced staves' voices/measures still don't interleave (疑事無功_piano po=7).
- The_Feels 1-line handclap staff detection (option B — Sources, +23 notes, 1 score).
- Dedicated dur/tie micro-fix (S8 regime) for the ~5 po-OK / dur-below-90 scores.
- The spike harness (`PDFCorpusGroundTruthSpikeTests.swift`) stays untracked;
  preserve it (copy) if the worktree is torn down.
