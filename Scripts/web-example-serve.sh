#!/usr/bin/env bash
#
# Serves the repository root over HTTP so Examples/Web can import
# Web/sheet-music-web with relative URLs.
#
# A file:// origin cannot do this: ES module imports and fetch() are both
# blocked there, and instantiating the wasm module wants a real Content-Type.
#
# Build first:
#   Scripts/wasm-build-web.sh
#   npm --prefix Web/sheet-music-web run build

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-8080}"

if [ ! -d "$REPO_ROOT/Web/sheet-music-web/dist" ]; then
    echo "error: Web/sheet-music-web/dist is missing — run Scripts/wasm-build-web.sh" >&2
    exit 1
fi
if [ ! -d "$REPO_ROOT/Web/sheet-music-web/dist-esm" ]; then
    echo "error: Web/sheet-music-web/dist-esm is missing —" >&2
    echo "       run npm --prefix Web/sheet-music-web run build" >&2
    exit 1
fi

echo "http://localhost:$PORT/Examples/Web/"
exec python3 -m http.server "$PORT" --directory "$REPO_ROOT"
