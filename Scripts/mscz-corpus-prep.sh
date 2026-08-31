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
# Seconds one score may take. Conversions run in about a second, but a score
# MuseScore cannot open hangs FOREVER at 0% CPU rather than failing (measured:
# one file held the run for 12 minutes before it was killed by hand), and one
# such file would otherwise stall a 669-file corpus indefinitely.
TIMEOUT="${MSCZ_PREP_TIMEOUT:-60}"

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
  # Two things are handled by handing the call to an inner bash:
  #
  # - the watchdog, which `timeout(1)` would otherwise provide (it is not on a
  #   stock macOS);
  # - the "Abort trap: 6" line, which is printed by the shell that WAITED on
  #   MuseScore rather than by MuseScore itself, so no redirect on the command
  #   can silence it — the inner shell's own stderr is what gets discarded.
  bash -c '
    "$1" -o "$2" "$3" >/dev/null 2>&1 &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$waited" -ge "$4" ]; then
        kill -9 "$pid" 2>/dev/null || true
        exit 124
      fi
      sleep 1
      waited=$((waited + 1))
    done
    wait "$pid"
  ' bash "$MSCORE" "$target" "$score" "$TIMEOUT" 2>/dev/null && status=0 || status=$?
  if [ "$status" -eq 124 ]; then
    # A killed export can leave a partial file behind, and a partial PDF
    # pairing with a score is worse than no pair: it would be measured.
    rm -f "$target"
    failed=$((failed + 1))
    echo "[prep-timeout] $relative" >&2
    continue
  fi
  if [ -f "$target" ]; then
    converted=$((converted + 1))
  else
    failed=$((failed + 1))
    echo "[prep-fail] $relative" >&2
  fi
done < <(find "$SRC" -name '*.mscz' -type f | sort)

echo "[prep] converted=$converted skipped=$skipped failed=$failed out=$OUT"
