#!/usr/bin/env bash
# Copies developer-supplied assets from ~/Desktop into the Android
# example's assets directory. All destinations are gitignored.
#
# Assets copied:
#   ~/Desktop/test.mscz  -> app/src/main/assets/test.mscz  (required)
#   ~/Desktop/gm.sf2     -> app/src/main/assets/gm.sf2     (optional — audio)
#
# If gm.sf2 is absent the app builds and parses scores normally; the
# Play button remains disabled (engine state stays STOPPED after prepare
# fails with AudioBackendException.NoSoundfont). Download a General MIDI
# SoundFont (e.g. GeneralUserGS.sf2 from schristiancollins.com) and
# save it as ~/Desktop/gm.sf2 to enable audio playback.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ASSETS_DIR="$ROOT/Examples/Android/app/src/main/assets"

# ── test.mscz (required) ─────────────────────────────────────────────────────

SRC_MSCZ="$HOME/Desktop/test.mscz"
DST_MSCZ="$ASSETS_DIR/test.mscz"

if [[ ! -f "$SRC_MSCZ" ]]; then
    echo "error: $SRC_MSCZ not found" >&2
    echo "      place a MuseScore file there (or a symlink) and rerun this script" >&2
    exit 1
fi

mkdir -p "$ASSETS_DIR"
cp "$SRC_MSCZ" "$DST_MSCZ"
echo "copied $SRC_MSCZ -> $DST_MSCZ"

# ── gm.sf2 (optional — enables audio playback) ───────────────────────────────

SRC_SF2="$HOME/Desktop/gm.sf2"
DST_SF2="$ASSETS_DIR/gm.sf2"

if [[ -f "$SRC_SF2" ]]; then
    cp "$SRC_SF2" "$DST_SF2"
    echo "copied $SRC_SF2 -> $DST_SF2"
else
    echo "WARNING: $SRC_SF2 not found — audio will be silent." >&2
    echo "         Download a General MIDI SoundFont (e.g. GeneralUserGS) and save as $SRC_SF2" >&2
fi
