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

# Raised from 4 MiB on 2026-09-06, when modeling one MuseScore element crossed
# it. The measurements, all brotli bytes of the probe:
#
#   main before that day's work   4,178,297
#   + FIGURED_BASS                  +6,414
#   + inline text markup (§7.1)    +22,427   -> 4,202,864, over 4 MiB by 8,560
#
# So a model-parity slice costs 6–22 KB, and roughly a dozen remain. 4 MiB had
# 16 KB of headroom left; it was going to be crossed by whoever went next.
#
# It was crossed by two, independently, the same afternoon. An unrelated branch
# adding lyric text entry came to 4,194,867 — **563 bytes over**, having spent
# 96% of the remaining headroom and missed by the last 4%. One branch over the
# line reads as that branch being large. Two, from different work, by 8,560 and
# by 563, reads as the line being in the wrong place.
#
# Those two also show that **counting types underestimates a change whose
# weight is logic.** §7.1 is the type-side example: three small types, but a
# field added to fourteen existing ones, regenerating fourteen `==` and
# fourteen memberwise inits, for 22,427. The lyric branch is the branch-side
# one: three new types, all small, and 14,430 anyway — the weight is three
# transition tables and a syllable rule, which are `switch` arms. Types emit
# metadata and witness tables; branches emit plain code, and plain code with
# few repeats is what brotli compresses worst. Predicting from the type count
# put that branch in the wrong half of the range.
#
# **This number is the wrong shape for what the gate detects**, and raising it
# does not fix that. The failure it exists to catch is a plain `import
# Foundation` drifting into a portable target, which costs about 10 MB — a
# step three orders of magnitude larger than a slice. An absolute line cannot
# tell that step apart from ordinary growth, so every time growth reaches the
# line a human has to decide which it was, and the answer is always "growth".
# A gate that hands its judgment back to a person on every firing is doing the
# opposite of its job.
#
# The shape that matches the detector is a delta — "no more than a few hundred
# KB above the current baseline" — which passes ordinary growth and still
# catches 10 MB by a factor of thirty.
#
# Do not implement that by committing the baseline to a file. A committed
# number is touched by every branch that changes size, so with several lanes in
# flight it conflicts on every merge, and it is the kind of conflict where
# taking either side is wrong — the true value is only knowable by measuring
# after the merge. Resolving it mechanically drifts the baseline away from
# reality, silently, which is worse than the absolute line this replaces. The
# absolute line's one virtue is that nobody has to update it.
#
# Measure the base instead: build the probe for `main` as well and compare the
# two. No stored number, so nothing to conflict and nothing to drift, at the
# cost of a second probe build. Whether that trade is worth it depends on how
# many lanes are running.
#
# **Re-check this when the next slice crosses the new ceiling.** If that has
# happened, the absolute form has failed twice and should be replaced rather
# than raised a second time.
CEILING_BYTES=$((9 * 1024 * 1024 / 2))
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
