#!/usr/bin/env bash
#
# Builds the wasm bridge's JavaScript bundle and stages it under
# Web/sheet-music-web/dist/.
#
# One build emits both hosts: `platforms/browser.js`, `platforms/node.js` and
# `platforms/browser.worker.js` sit alongside a shared `index.js`,
# `instantiate.js` and `runtime.js`. The `js` subcommand's `--platform` flag is
# advertised in its own `--help` but rejected as an unexpected argument in
# JavaScriptKit 0.57.1; it applies to `js test`, which picks a host to run in.
#
# --package-name is pinned rather than defaulted. The default is derived from the
# checkout's directory name, so building from a git worktree would stamp the
# worktree's name into the emitted package.json and the generated bundle would
# differ between two checkouts of the same commit.
#
# PackageToJS runs wasm-opt by default, so what lands in dist/ is the optimized
# artifact a page actually downloads. That is NOT the number
# `Scripts/wasm-size.sh` reports: the gate measures the whole portable graph
# through WasmSizeProbe, before optimization and with a deliberately wider
# surface. Both numbers matter and they are not interchangeable — as of this
# writing, 2.4 MB shipped against 3.6 MB at the gate.
#
# --disable-sandbox is required. PackageToJS is a SwiftPM command plugin,
# SwiftPM runs command plugins under the macOS sandbox, and the plugin
# npm-installs the JavaScript glue's dependencies. Without the flag it fails
# with ENOTFOUND against the npm registry even when the network is fine.
#
# Requires the open-source swift.org toolchain (Xcode's Swift has no WebAssembly
# backend), the matching Swift SDK, and binaryen for wasm-opt.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="swift-6.3.3-RELEASE_wasm"
BUILD_OUT="$REPO_ROOT/.build/plugins/PackageToJS/outputs/Package"
DEST="$REPO_ROOT/Web/sheet-music-web/dist"

if ! TOOLCHAIN="$("$REPO_ROOT/Scripts/swift-org-toolchain.sh")"; then
    echo "error: the swift.org Swift toolchain is not installed" >&2
    echo "       install it from https://www.swift.org/install/macos/ — see" >&2
    echo "       README \"Toolchain\" for why Xcode's Swift cannot be used" >&2
    exit 1
fi

if ! command -v wasm-opt >/dev/null 2>&1; then
    echo "error: wasm-opt not found (brew install binaryen)" >&2
    echo "       PackageToJS optimizes by default; without it the build fails" >&2
    exit 1
fi

export SWIFT_SHEET_MUSIC_WASM=1
export PATH="$TOOLCHAIN:$PATH"

echo "Building sheet-music-wasm ..."
"$TOOLCHAIN/swift" package \
    --package-path "$REPO_ROOT" \
    --disable-sandbox \
    --swift-sdk "$SDK" \
    js \
    --product sheet-music-wasm \
    --package-name sheet-music-wasm \
    -c release

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$BUILD_OUT/." "$DEST/"

wasm="$(find "$DEST" -maxdepth 1 -name '*.wasm' | head -1)"
if [ -z "$wasm" ]; then
    echo "error: no .wasm found under $DEST" >&2
    exit 1
fi
raw=$(wc -c <"$wasm" | tr -d ' ')
if command -v brotli >/dev/null 2>&1; then
    compressed=$(brotli -q 11 -c "$wasm" | wc -c | tr -d ' ')
    printf 'shipped wasm  raw %s B  brotli %s B\n' "$raw" "$compressed"
else
    printf 'shipped wasm  raw %s B  (brotli not installed)\n' "$raw"
fi
