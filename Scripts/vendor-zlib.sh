#!/usr/bin/env bash
# Stage the raw-DEFLATE subset of zlib into Sources/zlib.
#
# Usage: Scripts/vendor-zlib.sh <zlib-tarball> [dest-dir]
#
# Only what deflate/inflate need is copied. The gzip file-I/O translation
# units (gzclose/gzlib/gzread/gzwrite), the callback inflate variant
# (infback.c) and the one-shot wrappers (compress.c/uncompr.c) are left
# behind — this package drives deflate/inflate directly at
# windowBits = -15.
#
# `gzguts.h` is the one gzip file that is still needed: zutil.c includes
# it unconditionally outside Z_SOLO builds, and Z_SOLO is not an option
# here because it also removes zlib's default allocator, which
# DeflateZLib.swift relies on by leaving zalloc/zfree null.
#
# Only upstream files are replaced. The hand-written
# `include/module.modulemap` and `README.md` are left alone, so re-running
# this against a newer tarball is a copy rather than a merge.
set -euo pipefail

TARBALL="${1:?usage: vendor-zlib.sh <zlib-tarball> [dest-dir]}"
DEST="${2:-$(cd "$(dirname "$0")/.." && pwd -P)/Sources/zlib}"

PUBLIC_HEADERS=(zlib.h zconf.h)
PRIVATE_HEADERS=(crc32.h deflate.h gzguts.h inffast.h inffixed.h inflate.h inftrees.h trees.h zutil.h)
SOURCES=(adler32.c crc32.c deflate.c inffast.c inflate.c inftrees.c trees.c zutil.c)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tar xzf "$TARBALL" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'zlib-*' | head -1)"
if [ -z "$SRC" ]; then
    echo "error: no zlib-* directory in $TARBALL" >&2
    exit 1
fi

mkdir -p "$DEST/include"

for f in "${PUBLIC_HEADERS[@]}"; do
    cp "$SRC/$f" "$DEST/include/$f"
done
for f in "${PRIVATE_HEADERS[@]}" "${SOURCES[@]}"; do
    cp "$SRC/$f" "$DEST/$f"
done
cp "$SRC/LICENSE" "$DEST/LICENSE"

echo "staged ${#SOURCES[@]} sources from $(basename "$SRC") into $DEST"
