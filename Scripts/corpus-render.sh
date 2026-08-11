#!/usr/bin/env bash
# Render every score in a directory to one PNG each — the before/after
# pixel gate for layout refactors. The directory is an argument; no
# corpus path is committed.
#
#   Scripts/corpus-render.sh ~/Music/scores tmp/before [limit]
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <score-directory> <output-directory> [file-limit]" >&2
    exit 2
fi

export SM_RENDER_DIR="$1"
export SM_RENDER_OUT="$2"
if [ $# -ge 3 ]; then
    export SM_RENDER_LIMIT="$3"
fi

exec swift run render-previews
