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

export SWIFT_SHEET_MUSIC_WASM=1

echo "Building WasmSizeProbe for $SDK ..."
"$TOOLCHAIN/swift" build \
    --package-path "$REPO_ROOT" \
    --swift-sdk "$SDK" \
    --product WasmSizeProbe \
    -c release \
    -Xswiftc -gnone

WASM="$REPO_ROOT/.build/wasm32-unknown-wasip1/release/WasmSizeProbe.wasm"
if [ ! -f "$WASM" ]; then
    echo "error: expected artifact not found at $WASM" >&2
    exit 1
fi

raw_bytes=$(wc -c <"$WASM" | tr -d ' ')
compressed_bytes=$(brotli -q 11 -c "$WASM" | wc -c | tr -d ' ')

printf 'raw        %10s bytes (%.1f MB)\n' "$raw_bytes" "$(echo "$raw_bytes / 1048576" | bc -l)"
printf 'brotli     %10s bytes (%.1f MB)\n' "$compressed_bytes" "$(echo "$compressed_bytes / 1048576" | bc -l)"
printf 'ceiling    %10s bytes (%.1f MB)\n' "$CEILING_BYTES" "$(echo "$CEILING_BYTES / 1048576" | bc -l)"

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
