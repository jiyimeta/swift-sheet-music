#!/bin/bash
# Drive MSCZGroundTruthEvalHarness over a prepared .mscz corpus and keep only the
# lines worth reading: the per-file rows and the two mode summaries.
#
#   scripts/mscz-corpus-prep.sh ~/Documents/MuseScore3 ~/omr-mscz-corpus/pdf
#   scripts/mscz-corpus-eval.sh ~/Documents/MuseScore3 ~/omr-mscz-corpus/pdf 20
#
# RELEASE, for the reason every other OMR harness gives: the detector's forward
# pass in a debug build is slow enough to change what is practical to measure.
#
# Run this from a CLEAN worktree. It shells out to `swift test`, so pointing it at
# a tree someone is editing measures that tree's half-finished state.
set -euo pipefail

SRC="${1:?usage: mscz-corpus-eval.sh <mscz-root> <pdf-root> [limit]}"
PDFS="${2:?usage: mscz-corpus-eval.sh <mscz-root> <pdf-root> [limit]}"
LIMIT="${3:-20}"

OMR_MSCZ_EVAL=1 \
OMR_MSCZ_ROOT="$SRC" \
OMR_MSCZ_PDF_ROOT="$PDFS" \
OMR_MSCZ_LIMIT="$LIMIT" \
  swift test -c release --no-parallel --filter MSCZGroundTruthEvalHarness 2>&1 |
  grep -E '^\[mscz'
