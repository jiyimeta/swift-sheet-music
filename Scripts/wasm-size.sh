#!/usr/bin/env bash
#
# Measures the compressed WebAssembly size of the portable targets and fails if
# it regresses past the ceiling.
#
# The portable targets import `SheetMusicFoundation` rather than `Foundation`
# so that WebAssembly builds link `FoundationEssentials` instead of the
# ICU-carrying umbrella. That is worth roughly 10 MB brotli, and nothing in the
# compiler complains when a plain `import Foundation` drifts back into one of
# those targets — it still builds everywhere, it just quietly re-fattens the
# binary. A single such import is enough: this was measured twice while the
# migration was being done. This script is the gate that catches it.
#
# Usage:
#   Scripts/wasm-size.sh              # measure and enforce the ceiling
#   Scripts/wasm-size.sh --report     # measure and print, never fail
#
# Requires the open-source swift.org toolchain (Xcode's has no WebAssembly
# backend and crashes with "No available targets are compatible with triple
# wasm32-unknown-wasip1"), the matching Swift SDK, and brotli.

set -euo pipefail

CEILING_BYTES=$((4 * 1024 * 1024))
SDK="swift-6.3.3-RELEASE_wasm"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIZE_BUILD_DIR="$REPO_ROOT/.build/wasm-size"

report_only=0
if [ "${1:-}" = "--report" ]; then
    report_only=1
fi

if ! TOOLCHAIN="$("$REPO_ROOT/Scripts/swift-org-toolchain.sh")"; then
    echo "error: the swift.org Swift toolchain is not installed" >&2
    echo "       install it from https://www.swift.org/install/macos/ — see" >&2
    echo "       README \"Toolchain\" for why Xcode's Swift cannot be used" >&2
    exit 1
fi

if ! command -v brotli >/dev/null 2>&1; then
    echo "error: brotli not found (brew install brotli)" >&2
    exit 1
fi

if ! "$TOOLCHAIN/swift" sdk list | grep -q "^$SDK$"; then
    echo "error: Swift SDK '$SDK' is not installed" >&2
    echo "       swift sdk install https://download.swift.org/swift-6.3.3-release/wasm-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_wasm.artifactbundle.tar.gz --checksum <sha256>" >&2
    exit 1
fi

# `SerialLock` (Sources/SheetMusicFoundation/SerialLock.swift) does no real locking on
# WASI, because wasip1 is single-threaded. `wasip1-threads` is not, and no `#if` tells the
# two apart — both are `os(WASI)` — so the guard has to sit where such a build would be
# asked for. Read that file before lifting this.
case "$SDK" in
    *-threads | *threads*)
        echo "error: '$SDK' is a threaded WASI target, which SerialLock does not support" >&2
        echo "       see Sources/SheetMusicFoundation/SerialLock.swift — its WASI branch" >&2
        echo "       assumes a single thread and would silently stop serializing" >&2
        exit 1
        ;;
esac

export SWIFT_SHEET_MUSIC_WASM=1

echo "Building WasmSizeProbe for $SDK ..."
"$TOOLCHAIN/swift" build \
    --package-path "$REPO_ROOT" \
    --scratch-path "$SIZE_BUILD_DIR" \
    --disable-sandbox \
    --swift-sdk "$SDK" \
    --product WasmSizeProbe \
    -c release \
    -Xswiftc -gnone

WASM="$SIZE_BUILD_DIR/wasm32-unknown-wasip1/release/WasmSizeProbe.wasm"
if [ ! -f "$WASM" ]; then
    echo "error: expected artifact not found at $WASM" >&2
    exit 1
fi

raw_bytes=$(wc -c <"$WASM" | tr -d ' ')
compressed_bytes=$(brotli -q 11 -c "$WASM" | wc -c | tr -d ' ')

printf 'raw        %10s bytes (%.1f MB)\n' "$raw_bytes" "$(echo "$raw_bytes / 1048576" | bc -l)"
printf 'brotli     %10s bytes (%.1f MB)\n' "$compressed_bytes" "$(echo "$compressed_bytes / 1048576" | bc -l)"
printf 'ceiling    %10s bytes (%.1f MB)\n' "$CEILING_BYTES" "$(echo "$CEILING_BYTES / 1048576" | bc -l)"

# The ceiling above is measured over the whole portable graph through
# WasmSizeProbe, before wasm-opt and with MSCZWriter and EditWire deliberately
# linked in so a regression in either stays visible. What a page downloads is the
# PackageToJS artifact: a narrower surface, wasm-opt applied. Neither number
# substitutes for the other, so report both — and say so when the second one is
# absent rather than letting its silence read as zero.
SHIPPED_DIR="$REPO_ROOT/Web/sheet-music-web/dist"
shipped_wasm="$(find "$SHIPPED_DIR" -maxdepth 1 -name '*.wasm' 2>/dev/null | head -1)"
if [ -n "$shipped_wasm" ]; then
    shipped_raw=$(wc -c <"$shipped_wasm" | tr -d ' ')
    shipped_brotli=$(brotli -q 11 -c "$shipped_wasm" | wc -c | tr -d ' ')
    printf 'shipped    %10s bytes (%.1f MB)  raw %s\n' \
        "$shipped_brotli" "$(echo "$shipped_brotli / 1048576" | bc -l)" "$shipped_raw"
else
    echo "shipped    not measured (run Scripts/wasm-build-web.sh first)"
fi

if [ "$report_only" -eq 1 ]; then
    exit 0
fi

if [ "$compressed_bytes" -gt "$CEILING_BYTES" ]; then
    echo >&2
    echo "error: compressed size exceeds the ceiling." >&2
    echo "       The usual cause is a plain 'import Foundation' in a portable" >&2
    echo "       target; those must import SheetMusicFoundation instead. Check with:" >&2
    echo "         rg -n '^import Foundation\$' Sources/SheetMusic{Core,XMLTools,Zip,MIDI,MSCX,MusicXML,Layout,AudioCore,EditWire}" >&2
    echo "       Also check conditional imports inside '#if' blocks — one file is enough." >&2
    exit 1
fi

echo
echo "OK — under the ceiling."
