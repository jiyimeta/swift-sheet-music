#!/usr/bin/env bash
# Wraps each SheetMusicTests file that depends on an Apple framework or an
# Apple-platform test-support sub-library with
# `#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT` ... `#endif` so it
# compiles only in manifest shapes that define that dependency support.
# The search is scoped to `Tests/SheetMusicTests` because this guard matches
# the `SheetMusicTests` target's manifest conditions; other test targets have
# their own dependency shapes and should not inherit these predicates.
#
# Idempotent: skips files that already start with a known test-support guard.
set -euo pipefail

cd "$(dirname "$0")/.."

PATTERN='^[[:space:]]*(import (SwiftUI|AVFoundation|CoreText|AppKit|UIKit|PDFKit|CoreGraphics)|@testable import (SheetMusicAudio|SheetMusicUI|SheetMusicLayoutApple|SheetMusicPDF))$'
APPLE_TEST_SUPPORT_GUARD="#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT"
ANDROID_JNI_TEST_SUPPORT_GUARD="#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT"

FILES=()
while IFS= read -r line; do
    FILES+=("$line")
done < <(grep -rlE "$PATTERN" Tests/SheetMusicTests --include='*.swift' | sort -u)

echo "Found ${#FILES[@]} Apple-dependent test files."
if [[ ${#FILES[@]} -eq 0 ]]; then
    exit 0
fi

for f in "${FILES[@]}"; do
    first_line=$(head -n 1 "$f")
    if [[ "$first_line" == "$APPLE_TEST_SUPPORT_GUARD" \
       || "$first_line" == "$ANDROID_JNI_TEST_SUPPORT_GUARD" ]]; then
        echo "  skip (already gated): $f"
        continue
    fi
    if grep -qE '^#if SHEET_MUSIC_HAS_(APPLE_PLATFORM|ANDROID_JNI)_TEST_SUPPORT$' "$f"; then
        echo "  skip (contains scoped test-support guard): $f"
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
        echo "$APPLE_TEST_SUPPORT_GUARD"
        cat "$f"
        echo "#endif"
    } > "$tmp"
    mv "$tmp" "$f"
    echo "  gated: $f"
done
