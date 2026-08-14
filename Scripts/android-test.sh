#!/usr/bin/env bash
# Build the test bundle for an Android target and run it on a connected
# device via adb. Exits with the device-side test exit code.
#
# Usage: Scripts/android-test.sh <target> [serial] [-- <swift-test-args>]
#   target: aarch64 | x86_64 (mapped to *-unknown-linux-android28)
#   serial: optional adb device serial (use when multiple devices attached)
#
# The triple's API-level component (android28) is the lowest level provided
# by the Swift 6.3.3 official Android SDK (`swift-6.3.3-RELEASE_android`).
# The bundle name `swift-6.3.3-RELEASE_android` also works as a `--swift-sdk`
# value but lets SwiftPM pick the API level, so we use the triple form for
# explicitness and to match aarch64/x86_64 selection.
set -euo pipefail

# Use the open-source swift.org toolchain paired with the Android SDK.
# Prepend it to PATH so plain `swift` resolves to it (the swiftly shim on
# some hosts ignores TOOLCHAINS; Apple's Xcode swiftc produces incompatible
# swiftmodules).
if TOOLCHAIN_BIN="$("$(dirname "$0")/swift-org-toolchain.sh")"; then
    export PATH="$TOOLCHAIN_BIN:$PATH"
fi

cd "$(dirname "$0")/.."

TARGET_SHORT="${1:?usage: android-test.sh <aarch64|x86_64> [serial]}"
case "$TARGET_SHORT" in
    aarch64) TRIPLE="aarch64-unknown-linux-android28" ;;
    x86_64)  TRIPLE="x86_64-unknown-linux-android28" ;;
    *) echo "unknown target: $TARGET_SHORT" >&2; exit 2 ;;
esac

SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.3-RELEASE_android.artifactbundle"
if [[ ! -e "$SDK_BUNDLE/swift-android/ndk-sysroot" ]]; then
    cat >&2 <<EOF
error: NDK sysroot is not staged.
  Run the one-time setup:
    ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/<version> \\
        $SDK_BUNDLE/swift-android/scripts/setup-android-sdk.sh
EOF
    exit 4
fi

SERIAL_ARG=""
if [[ "${2:-}" != "" && "${2:-}" != "--" ]]; then
    SERIAL_ARG="-s $2"
    shift 2
else
    shift 1
fi

# Drop the optional `--` separator before xctest args.
if [[ "${1:-}" == "--" ]]; then
    shift 1
fi

# Anything left in $@ is forwarded verbatim to the xctest binary on-device.

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

# Push the Swift Android SDK runtime shared libraries (libFoundation.so,
# libswiftSwiftOnoneSupport.so, etc.) that live in the artifact bundle and
# are not copied into the build directory.
SWIFT_RT_DIR="$SDK_BUNDLE/swift-android/swift-resources/usr/lib/swift-$TARGET_SHORT/android"
if [[ -d "$SWIFT_RT_DIR" ]]; then
    find "$SWIFT_RT_DIR" -maxdepth 1 -name '*.so' -type f -print0 \
        | xargs -0 -I{} adb $SERIAL_ARG push {} "$REMOTE_DIR/" >/dev/null
fi

# The Swift Android runtime depends on the NDK's libc++_shared.so. Push it
# from the staged NDK sysroot alongside the Swift libs.
case "$TARGET_SHORT" in
    aarch64) NDK_TRIPLE="aarch64-linux-android" ;;
    x86_64)  NDK_TRIPLE="x86_64-linux-android" ;;
esac
NDK_CXX_SO="$SDK_BUNDLE/swift-android/ndk-sysroot/usr/lib/$NDK_TRIPLE/libc++_shared.so"
if [[ -e "$NDK_CXX_SO" ]]; then
    adb $SERIAL_ARG push "$NDK_CXX_SO" "$REMOTE_DIR/" >/dev/null
fi

# Push the test resource bundle (MSCX fixtures, reference MIDIs).
RESOURCE_BUNDLE=$(find "$BUILD_DIR" -maxdepth 2 -name '*_SheetMusicTests.resources' -type d | head -n 1)
if [[ -n "$RESOURCE_BUNDLE" ]]; then
    adb $SERIAL_ARG push "$RESOURCE_BUNDLE" "$REMOTE_DIR/" >/dev/null
fi

XCTEST_NAME=$(basename "$XCTEST_BIN")
XCTEST_ARGS="$*"

# Notes for the device invocation:
#  * Swift Foundation on Android resolves zlib symbols lazily from a
#    `libz.so` in the runtime linker namespace. Apps started from
#    `/data/local/tmp` do not pick up the system libz automatically, so
#    we LD_PRELOAD `/system/lib64/libz.so` to satisfy `deflateInit2_` etc.
#  * The package uses Swift Testing (`import Testing`), not XCTest. The
#    test bundle's default entrypoint is the XCTest harness, which finds
#    zero tests in our suite. We pass `--testing-library swift-testing`
#    so Swift Testing's runner takes over.
echo "==> Running tests on device"
adb $SERIAL_ARG shell "
    cd $REMOTE_DIR &&
    chmod +x ./$XCTEST_NAME &&
    LD_LIBRARY_PATH=$REMOTE_DIR \
    LD_PRELOAD=/system/lib64/libz.so \
    ./$XCTEST_NAME --testing-library swift-testing $XCTEST_ARGS
"
