#!/usr/bin/env bash
# Build SheetMusicJNI for each enabled Android ABI and stage .so files
# (plus Swift runtime stubs) into Examples/Android/app/src/main/jniLibs/.
set -euo pipefail

: "${TOOLCHAINS:=org.swift.632202605101a}"
export TOOLCHAINS
export SWIFT_SHEET_MUSIC_ANDROID=1

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
JNI_DIR="$ROOT/Examples/Android/app/src/main/jniLibs"
SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle"

# Actual layout (Swift 6.3.2 Android SDK, verified 2026-05-19):
#   $SDK_BUNDLE/swift-android/swift-resources/usr/lib/swift-<arch>/android/libswiftCore.so
# The plan-assumed path ($SDK_BUNDLE/swift-android/sysroot/usr/lib/<arch>)
# does not exist in this release; use swift-resources instead.
RUNTIME_BASE="$SDK_BUNDLE/swift-android/swift-resources/usr/lib"

mkdir -p "$JNI_DIR"

# Each entry: "<triple>:<abi>:<swift-arch-dir>"
# Bash 3.2 (macOS default) doesn't support declare -A; use a plain array of colon-delimited tuples.
TARGETS=(
    "aarch64-unknown-linux-android28:arm64-v8a:swift-aarch64"
    "x86_64-unknown-linux-android28:x86_64:swift-x86_64"
)

for entry in "${TARGETS[@]}"; do
    triple="${entry%%:*}"
    rest="${entry#*:}"
    abi="${rest%%:*}"
    arch="${rest#*:}"

    echo
    echo "==> Building libSheetMusicJNI.so for $abi ($triple)"
    swift build --package-path "$ROOT" \
                --product SheetMusicJNI \
                --swift-sdk "$triple" \
                -c release

    src_so="$ROOT/.build/$triple/release/libSheetMusicJNI.so"
    dst_dir="$JNI_DIR/$abi"
    mkdir -p "$dst_dir"
    cp "$src_so" "$dst_dir/"

    echo "==> Staging Swift runtime stubs into $dst_dir"
    runtime_src="$RUNTIME_BASE/$arch/android"
    if [[ ! -d "$runtime_src" ]]; then
        echo "error: Swift runtime not found at $runtime_src" >&2
        echo "      Re-derive the path from your installed Swift Android SDK." >&2
        exit 1
    fi
    for so in libswiftCore.so libswift_Concurrency.so libswiftAndroid.so \
              libFoundation.so libFoundationEssentials.so \
              libFoundationInternationalization.so libdispatch.so \
              libBlocksRuntime.so; do
        if [[ -f "$runtime_src/$so" ]]; then
            cp -L "$runtime_src/$so" "$dst_dir/"
        fi
    done
done

echo
echo "Done. libSheetMusicJNI.so + runtime staged under:"
echo "  $JNI_DIR/{arm64-v8a,x86_64}/"
echo
echo "Next: place ~/Desktop/test.mscz and run"
echo "      Scripts/android-bundle-test-score.sh"
