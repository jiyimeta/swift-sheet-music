#!/bin/bash
# Two-stage coordinate sweep of the three decode constants over the v2-eval set.
# Stage 1 moves threshold alone; stage 2 moves topK x nms around stage 1's winner.
# Everything else (model, data root, mode) is held fixed.
#
# This drives OMRDetectorEvalHarness (Tests/SheetMusicTests/OMRDetectorEvalTests.swift),
# NOT OMRHybridEvalHarness. OMRDetectorEvalHarness is the harness whose
# `[detect][SUMMARY]` line actually carries the pitchP50/pitchMean/durP50/durMean
# metrics this sweep picks a winner from (see printScoreSummary there);
# OMRHybridEvalHarness's `[hybrid][SUMMARY]` line carries none of them
# (mode/jitterSp/rows/vFloorSp/vBeamedFloorSp/stemHeadEndTolSp/peakRSS only), so
# pointing this script at it would build and run repeatedly and produce nothing to
# compare. Do not "simplify" this back to the hybrid harness.
#
# Run this from a CLEAN worktree. It shells out to `swift test`, so pointing it at a
# tree someone is editing measures that tree's half-finished state.
set -euo pipefail
: "${OMR_DATA_ROOT:?set OMR_DATA_ROOT}"
: "${OMR_MODEL_ROOT:?set OMR_MODEL_ROOT}"
WINNING_THRESHOLD="${1:-}"

run() {
  echo "[sweep] threshold=$1 topK=$2 nms=$3"
  OMR_DETECT_EVAL=1 OMR_DATA_ROOT="$OMR_DATA_ROOT" OMR_MODEL_ROOT="$OMR_MODEL_ROOT" \
  OMR_DECODE_THRESHOLD="$1" OMR_DECODE_TOP_K="$2" OMR_DECODE_NMS_SP="$3" \
    swift test -c release --no-parallel --filter OMRDetectorEvalHarness 2>&1 |
    grep -E '^\[detect\]\[SUMMARY\]|^\[detect-override\]'
}

if [ -z "$WINNING_THRESHOLD" ]; then
  for threshold in 0.20 0.25 0.30 0.35 0.40; do
    run "$threshold" 300 0.5
  done
  echo "[sweep] stage 1 done — re-run with the winning threshold as \$1 for stage 2"
  exit 0
fi

for topk in 200 300 400; do
  for nms in 0.35 0.50 0.65; do
    run "$WINNING_THRESHOLD" "$topk" "$nms"
  done
done
