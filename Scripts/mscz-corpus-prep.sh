#!/bin/bash
# Convert a local .mscz library to PDFs, mirroring the source tree's layout, so
# MSCZGroundTruthEvalHarness can pair each score with the PDF made from it.
#
#   scripts/mscz-corpus-prep.sh ~/Documents/MuseScore3 ~/omr-mscz-corpus/pdf [limit]
#
# Every score carries its own answer, which is what makes this corpus worth the
# conversion: a copyrighted-PDF corpus can only be read, never scored.
#
# RESUMABLE. A score whose .pdf already exists is skipped, so a 669-file run can
# be interrupted and restarted; delete the output tree to force a re-convert.
#
# MuseScore's CLI writes crash-handler noise to stderr on exit even when the
# export succeeded (observed on MuseScore 4 / macOS 15), so success is decided by
# the output file existing, never by the exit status or by stderr being quiet.
set -euo pipefail

SRC="${1:?usage: mscz-corpus-prep.sh <mscz-root> <pdf-root> [limit]}"
OUT="${2:?usage: mscz-corpus-prep.sh <mscz-root> <pdf-root> [limit]}"
LIMIT="${3:-0}"
MSCORE="${MSCORE:-/Applications/MuseScore 4.app/Contents/MacOS/mscore}"

if [ ! -x "$MSCORE" ]; then
  echo "no MuseScore CLI at $MSCORE (set MSCORE=…)" >&2
  exit 1
fi

converted=0
skipped=0
failed=0
seen=0

# Sorted, so `limit` takes the same prefix the harness's own `limit` does.
while IFS= read -r score; do
  relative="${score#"$SRC"/}"
  target="$OUT/${relative%.mscz}.pdf"
  seen=$((seen + 1))
  if [ "$LIMIT" -gt 0 ] && [ "$seen" -gt "$LIMIT" ]; then
    break
  fi
  if [ -f "$target" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  mkdir -p "$(dirname "$target")"
  # MuseScore aborts on exit AFTER writing the file. "Abort trap: 6" is then
  # printed by the shell that WAITED on it, not by MuseScore, so no redirect
  # on the command itself can silence it — the call is handed to an inner
  # bash whose own stderr is the thing being discarded.
  bash -c '"$0" -o "$1" "$2" >/dev/null 2>&1' \
    "$MSCORE" "$target" "$score" 2>/dev/null || true
  if [ -f "$target" ]; then
    converted=$((converted + 1))
  else
    failed=$((failed + 1))
    echo "[prep-fail] $relative" >&2
  fi
done < <(find "$SRC" -name '*.mscz' -type f | sort)

echo "[prep] converted=$converted skipped=$skipped failed=$failed out=$OUT"
