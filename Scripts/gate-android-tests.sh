#!/usr/bin/env bash
# Wraps each test file that depends on an Apple framework or an
# Apple-only sub-library with `#if !os(Android)` ... `#endif` so it
# compiles on Apple platforms but vanishes on Android cross-builds.
#
# Idempotent: skips files that already start with `#if !os(Android)`.
set -euo pipefail

cd "$(dirname "$0")/.."

PATTERN='import SwiftUI|import AVFoundation|import CoreText|import AppKit|import UIKit|import PDFKit|import CoreGraphics|import ZIPFoundation|@testable import SheetMusicAudio|@testable import SheetMusicUI|@testable import SheetMusicLayout|@testable import SheetMusicPDF'

FILES=()
while IFS= read -r line; do
    FILES+=("$line")
done < <(grep -rlE "$PATTERN" Tests/ --include='*.swift' | sort -u)

echo "Found ${#FILES[@]} Apple-dependent test files."

for f in "${FILES[@]}"; do
    first_line=$(head -n 1 "$f")
    if [[ "$first_line" == "#if !os(Android)" ]]; then
        echo "  skip (already gated): $f"
        continue
    fi
    # Files already starting with an Apple-only #if guard
    # (os(macOS), os(iOS), canImport(<Apple framework>), etc.)
    # don't need !os(Android) wrapping — on Android those guards
    # evaluate to false and the entire file is excluded. Double-
    # wrapping also triggers SwiftFormat to add an extra indent
    # level, which can push existing 120-char lines past the limit.
    if [[ "$first_line" == "#if os(macOS)"* \
       || "$first_line" == "#if os(iOS)"* \
       || "$first_line" == "#if canImport(CoreGraphics)"* \
       || "$first_line" == "#if canImport(QuartzCore)"* ]]; then
        echo "  skip (Apple-only guard already present): $f"
        continue
    fi
    tmp=$(mktemp)
    {
        echo "#if !os(Android)"
        cat "$f"
        echo "#endif"
    } > "$tmp"
    mv "$tmp" "$f"
    echo "  gated: $f"
done
