#!/usr/bin/env bash
# Draw-program parity probe: render the same LayoutDocument through the Apple
# renderer and through a CoreGraphics walk of its DrawCommand stream, and diff
# the bitmaps. The Windows renderer will be measured against the same Apple
# render, so the budget here is the one it inherits.
#
#   Scripts/parity-probe.sh samples tmp/parity            # every Samples.catalog score
#   Scripts/parity-probe.sh ~/Music/foo.mscz tmp/parity   # one score
#   Scripts/parity-probe.sh samples tmp/parity 1.5        # exit 1 above 1.5 % mean differing pixels
#
# Release build on purpose: the ±3 px shift search is slow in debug.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <samples|score-path> <output-directory> [max-mean-percent]" >&2
    exit 2
fi

export SM_PARITY="$1"
export SM_PARITY_OUT="$2"
if [ $# -ge 3 ]; then
    export SM_PARITY_MAX_MEAN="$3"
fi

exec swift run -c release render-previews
