#!/usr/bin/env bash
# Build the test bundle for an Android target and run it on a connected
# device via adb. Exits with the device-side test exit code.
#
# Usage: Scripts/android-test.sh <target> [serial] [-- <swift-test-args>]
#   target: aarch64 | x86_64 (mapped to *-unknown-linux-android28)
#   serial: optional adb device serial (use when multiple devices attached)
#
# The triple's API-level component (android28) is the lowest level provided
# by the Swift 6.3.2 official Android SDK (`swift-6.3.2-RELEASE_android`).
# The bundle name `swift-6.3.2-RELEASE_android` also works as a `--swift-sdk`
# value but lets SwiftPM pick the API level, so we use the triple form for
# explicitness and to match aarch64/x86_64 selection.
set -euo pipefail

# Use the open-source swift.org toolchain (the one paired with the Android
# SDK). Apple's Xcode-shipped swiftc produces incompatible swiftmodules.
export TOOLCHAINS="${TOOLCHAINS:-org.swift.632202605101a}"

cd "$(dirname "$0")/.."

TARGET_SHORT="${1:?usage: android-test.sh <aarch64|x86_64> [serial]}"
case "$TARGET_SHORT" in
    aarch64) TRIPLE="aarch64-unknown-linux-android28" ;;
    x86_64)  TRIPLE="x86_64-unknown-linux-android28" ;;
    *) echo "unknown target: $TARGET_SHORT" >&2; exit 2 ;;
esac

SERIAL_ARG=""
if [[ "${2:-}" != "" && "${2:-}" != "--" ]]; then
    SERIAL_ARG="-s $2"
fi

REMOTE_DIR=/data/local/tmp/swift-sheet-music-test

echo "==> Cross-compiling for $TRIPLE"
SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
    --swift-sdk "$TRIPLE" \
    --build-tests

BUILD_DIR=".build/$TRIPLE/debug"
XCTEST_BIN=$(find "$BUILD_DIR" -maxdepth 2 -name '*PackageTests.xctest' -type f | head -n 1)
if [[ -z "$XCTEST_BIN" ]]; then
    echo "could not locate xctest binary under $BUILD_DIR" >&2
    exit 3
fi

echo "==> Pushing test bundle to device"
adb $SERIAL_ARG shell "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
adb $SERIAL_ARG push "$XCTEST_BIN" "$REMOTE_DIR/" >/dev/null

# Push all runtime .so dependencies sitting next to the test binary.
find "$BUILD_DIR" -maxdepth 2 -name '*.so' -type f -print0 \
    | xargs -0 -I{} adb $SERIAL_ARG push {} "$REMOTE_DIR/" >/dev/null

# Push the test resource bundle (MSCX fixtures, reference MIDIs).
RESOURCE_BUNDLE=$(find "$BUILD_DIR" -maxdepth 2 -name '*_SheetMusicTests.resources' -type d | head -n 1)
if [[ -n "$RESOURCE_BUNDLE" ]]; then
    adb $SERIAL_ARG push "$RESOURCE_BUNDLE" "$REMOTE_DIR/" >/dev/null
fi

XCTEST_NAME=$(basename "$XCTEST_BIN")

echo "==> Running tests on device"
adb $SERIAL_ARG shell "
    cd $REMOTE_DIR &&
    chmod +x ./$XCTEST_NAME &&
    LD_LIBRARY_PATH=$REMOTE_DIR ./$XCTEST_NAME ${@:3}
"
