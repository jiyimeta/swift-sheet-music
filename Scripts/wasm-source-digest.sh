#!/usr/bin/env bash
#
# Prints one sha256 over every source file that decides what the WebAssembly
# build behaves like. `Scripts/wasm-build-web.sh` records it next to the binary
# it just produced; `Web/sheet-music-web/test/wasm-freshness.test.ts`
# recomputes it and fails the browser suite when the two disagree.
#
# Why this exists: `dist/` is gitignored, so the binary the browser tests load
# is whatever a rebuild last left there — a checkout, a rebase or a branch
# switch moves the Swift sources under it without touching it. Nothing in the
# suite noticed. `engineVersionStamp()` cannot notice either: it is an FNV-1a
# digest of the hand-edited `SheetMusicEngine.version` string, so every build
# between two releases stamps the same number (`SheetMusicEngine.swift` says as
# much — a stale image at an unchanged version is exactly what it is blind to).
# A digest of the sources is the smallest thing that actually distinguishes
# "built from this tree" from "built from some tree".
#
# Paths are hashed RELATIVE to the repository root, so two worktrees of the
# same commit produce the same digest and a wasm built in one is legitimately
# fresh in the other.
#
# The file set is an EXCLUDE list on purpose. Over-inclusion costs a needless
# rebuild; under-inclusion makes the gate blind, which is the bug this closes.
# So a new portable target is covered the moment it is added, and only the
# subtrees below — Apple-only, Android-only, or tooling that the shipped
# product never links — have to be maintained by hand.
#
#     Scripts/wasm-source-digest.sh [repo-root]

set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_ROOT"

# Not in the `sheet-music-wasm` graph: Apple hosts and UI, the Android JNI
# bridge, the codegen tools, and the two wasm probes (which link the bridge but
# ship nothing).
EXCLUDED=(
    CJNI
    CSequencerHostTime
    GenSMuFLTables
    RenderPreviews
    SheetMusic
    SheetMusicAndroidJNI
    SheetMusicAudio
    SheetMusicAudioApple
    SheetMusicAudioSwiftySynth
    SheetMusicLayoutApple
    SheetMusicLoader
    SheetMusicPDF
    SheetMusicUI
    WasmParityProbe
    WasmSizeProbe
)

roots=()
for entry in Sources/*/; do
    name="${entry#Sources/}"
    name="${name%/}"
    skip=""
    for excluded in "${EXCLUDED[@]}"; do
        if [ "$name" = "$excluded" ]; then
            skip=1
            break
        fi
    done
    [ -n "$skip" ] || roots+=("$entry")
done

if [ ${#roots[@]} -eq 0 ]; then
    echo "error: no source directories matched under $REPO_ROOT/Sources" >&2
    exit 1
fi

# The manifest decides which targets and settings exist, `Package.resolved`
# pins the dependency revisions that get linked in, and the build script owns
# the flags — all three change the binary without changing a single source file.
extra=(Package.swift Package.resolved Scripts/wasm-build-web.sh)
for file in "${extra[@]}"; do
    if [ ! -f "$file" ]; then
        echo "error: expected $file under $REPO_ROOT" >&2
        exit 1
    fi
done

find "${roots[@]}" "${extra[@]}" -type f \
    \( -name '*.swift' -o -name '*.c' -o -name '*.h' -o -name '*.modulemap' \
    -o -name 'Package.resolved' -o -name 'wasm-build-web.sh' \) -print0 |
    LC_ALL=C sort -z |
    xargs -0 shasum -a 256 |
    shasum -a 256 |
    cut -d' ' -f1
