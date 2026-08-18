#!/usr/bin/env bash
#
# Converts the two fonts the browser renderer draws with into woff2 and stages
# them under Web/sheet-music-web/assets/.
#
# Both are already vendored for other platforms and both are SIL OFL 1.1:
#   Bravura     — Sources/SheetMusicLayoutApple/Fonts/Resources/Bravura.otf
#   Edwin-Roman — Android/SheetMusicComposeAndroid/src/main/assets/fonts/Edwin-Roman.otf
# Nothing new is redistributed here; the same faces get a second container. See
# NOTICE.
#
# The renderer only rasterizes glyphs whose positions the engraver already
# decided — the geometry comes from assets/bravura.smft, which
# Tools/GenBravuraMetrics produces. These files change what the page looks like,
# not where anything is.
#
# Requires woff2 (brew install woff2). The output is committed, so this runs only
# when a font is replaced.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/Web/sheet-music-web/assets"

if ! command -v woff2_compress >/dev/null 2>&1; then
    echo "error: woff2_compress not found (brew install woff2)" >&2
    exit 1
fi

mkdir -p "$DEST"

# woff2_compress writes next to its input and offers no output path, so each
# conversion runs against a copy in a scratch directory.
convert() {
    src="$1"
    out="$2"
    if [ ! -f "$src" ]; then
        echo "error: source font not found at $src" >&2
        exit 1
    fi
    tmp="$(mktemp -d)"
    base="$(basename "$src")"
    cp "$src" "$tmp/$base"
    woff2_compress "$tmp/$base" >/dev/null
    mv "$tmp/${base%.otf}.woff2" "$DEST/$out"
    rm -rf "$tmp"
    echo "wrote $DEST/$out ($(wc -c <"$DEST/$out" | tr -d ' ') bytes)"
}

convert "$REPO_ROOT/Sources/SheetMusicLayoutApple/Fonts/Resources/Bravura.otf" bravura.woff2
convert \
    "$REPO_ROOT/Android/SheetMusicComposeAndroid/src/main/assets/fonts/Edwin-Roman.otf" \
    edwin-roman.woff2

cp "$REPO_ROOT/Sources/SheetMusicLayoutApple/Fonts/Resources/Bravura.LICENSE.txt" \
    "$DEST/Bravura.LICENSE.txt"
cp "$REPO_ROOT/Android/SheetMusicComposeAndroid/src/main/assets/fonts/Edwin.LICENSE.txt" \
    "$DEST/Edwin.LICENSE.txt"
echo "copied licences"
