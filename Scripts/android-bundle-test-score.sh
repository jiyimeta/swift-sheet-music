#!/usr/bin/env bash
# Copies a developer-supplied test.mscz from ~/Desktop into the Android
# example's assets directory. The destination is gitignored.
set -euo pipefail

SRC="$HOME/Desktop/test.mscz"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DST="$ROOT/Examples/Android/app/src/main/assets/test.mscz"

if [[ ! -f "$SRC" ]]; then
    echo "error: $SRC not found" >&2
    echo "      place a MuseScore file there (or a symlink) and rerun this script" >&2
    exit 1
fi

mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"
echo "copied $SRC -> $DST"
