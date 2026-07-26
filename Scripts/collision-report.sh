#!/usr/bin/env bash
# Run the annotation-collision detector over a directory of MuseScore
# files. The directory is an argument — no corpus path is committed.
#
#   Scripts/collision-report.sh ~/Documents/MuseScore3/スコア [limit]
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <score-directory> [file-limit]" >&2
    exit 2
fi

export SM_COLLIDE_DIR="$1"
if [ $# -ge 2 ]; then
    export SM_COLLIDE_LIMIT="$2"
fi

exec swift run render-previews
