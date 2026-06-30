#!/usr/bin/env bash
# Extract the SMuFL glyphnames subset this package needs from a full
# glyphnames.json (SMuFL data; codepoints are facts). Source defaults to
# the MuseScore clone. Usage: extract-glyphnames-subset.sh [path-to-glyphnames.json]
set -euo pipefail
SRC="${1:-$HOME/Developer/musescore/MuseScore/fonts/smufl/glyphnames.json}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Tools/smufl/glyphnames-subset.json"
mkdir -p "$(dirname "$OUT")"
# glyphnames.json entries look like: "noteheadBlack": { "codepoint": "U+E0A4", ... }
# Emit a flat { name: <int> } map for names in the ranges + explicit list we use.
python3 "$(dirname "$0")/extract_glyphnames_subset.py" "$SRC" "$OUT"
echo "wrote $OUT"
