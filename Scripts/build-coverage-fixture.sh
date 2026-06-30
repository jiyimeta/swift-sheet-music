#!/usr/bin/env bash
# build-coverage-fixture.sh
#
# Packages Scripts/coverage-fixture.mscx into a MuseScore 4 .mscz bundle
# and copies both the .mscx and .mscz to ~/Desktop/.
#
# Usage:
#   Scripts/build-coverage-fixture.sh
#
# No arguments needed. Run from any directory inside the repository.
# Requires: zip (pre-installed on macOS).

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
FIXTURE_NAME="notation-coverage-fixture"
SRC_MSCX="${SCRIPT_DIR}/coverage-fixture.mscx"
OUT_DIR="${TMPDIR:-/tmp}/coverage-fixture-build"
DESKTOP="${HOME}/Desktop"

# ── 1. Validate source exists ─────────────────────────────────────────────────
if [[ ! -f "${SRC_MSCX}" ]]; then
  echo "Error: source fixture not found at ${SRC_MSCX}" >&2
  exit 1
fi

# ── 2. Stage files in a temp directory ───────────────────────────────────────
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}/META-INF"

# The inner MSCX inside the ZIP is named to match the archive
cp "${SRC_MSCX}" "${OUT_DIR}/${FIXTURE_NAME}.mscx"

# META-INF/container.xml: standard MuseScore container manifest
cat > "${OUT_DIR}/META-INF/container.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<container>
  <rootfiles>
    <rootfile full-path="notation-coverage-fixture.mscx"/>
  </rootfiles>
</container>
EOF

# ── 3. Zip into .mscz ─────────────────────────────────────────────────────────
MSCZ_OUT="${OUT_DIR}/${FIXTURE_NAME}.mscz"
# Must zip from inside the staging directory so paths in the archive are relative
( cd "${OUT_DIR}" && zip -q "${MSCZ_OUT}" "META-INF/container.xml" "${FIXTURE_NAME}.mscx" )

# ── 4. Copy to Desktop ────────────────────────────────────────────────────────
cp "${SRC_MSCX}" "${DESKTOP}/${FIXTURE_NAME}.mscx"
cp "${MSCZ_OUT}" "${DESKTOP}/${FIXTURE_NAME}.mscz"

echo "Delivered:"
echo "  ${DESKTOP}/${FIXTURE_NAME}.mscx"
echo "  ${DESKTOP}/${FIXTURE_NAME}.mscz"
