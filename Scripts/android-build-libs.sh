#!/usr/bin/env bash
# Build SheetMusicJNI for each enabled Android ABI and stage .so files
# (plus Swift runtime stubs) into Android/SheetMusicAndroid/src/main/jniLibs/.
set -euo pipefail

: "${TOOLCHAINS:=org.swift.632202605101a}"
export TOOLCHAINS
export SWIFT_SHEET_MUSIC_ANDROID=1

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
JNI_DIR="$ROOT/Android/SheetMusicAndroid/src/main/jniLibs"
SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle"

# Actual layout (Swift 6.3.2 Android SDK, verified 2026-05-19):
#   $SDK_BUNDLE/swift-android/swift-resources/usr/lib/swift-<arch>/android/libswiftCore.so
# The plan-assumed path ($SDK_BUNDLE/swift-android/sysroot/usr/lib/<arch>)
# does not exist in this release; use swift-resources instead.
RUNTIME_BASE="$SDK_BUNDLE/swift-android/swift-resources/usr/lib"

# Locate the NDK so we can also stage libc++_shared.so per ABI. The Swift
# runtime depends on it but it's an NDK artifact, not part of the Swift
# Android SDK. Honour ANDROID_NDK_HOME if set, else auto-discover under
# $ANDROID_HOME/ndk/<version>/ (pick the newest version present).
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    sdk_root="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    if [[ -d "$sdk_root/ndk" ]]; then
        ANDROID_NDK_HOME="$(ls -d "$sdk_root"/ndk/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/$::')"
    fi
fi
if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "$ANDROID_NDK_HOME" ]]; then
    echo "error: could not locate Android NDK; set ANDROID_NDK_HOME" >&2
    exit 1
fi
NDK_LIB_BASE="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib"

mkdir -p "$JNI_DIR"

# Each entry: "<triple>:<abi>:<swift-arch-dir>:<ndk-triple>"
# Bash 3.2 (macOS default) doesn't support declare -A; use a plain array of colon-delimited tuples.
TARGETS=(
    "aarch64-unknown-linux-android28:arm64-v8a:swift-aarch64:aarch64-linux-android"
    "x86_64-unknown-linux-android28:x86_64:swift-x86_64:x86_64-linux-android"
)

for entry in "${TARGETS[@]}"; do
    triple="${entry%%:*}"
    rest="${entry#*:}"
    abi="${rest%%:*}"
    rest="${rest#*:}"
    arch="${rest%%:*}"
    ndk_triple="${rest#*:}"

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

    # PoC: swift-java-backed bridge alongside the hand-written one.
    # See project_swift_java_strategy.md memory + Sources/SheetMusicAndroidJNISwiftJava/.
    echo "==> Building libSheetMusicJNISwiftJava.so for $abi (swift-java)"
    swift build --package-path "$ROOT" \
                --product SheetMusicJNISwiftJava \
                --swift-sdk "$triple" \
                -c release
    cp "$ROOT/.build/$triple/release/libSheetMusicJNISwiftJava.so" "$dst_dir/"
    cp "$ROOT/.build/$triple/release/libSwiftJava.so" "$dst_dir/"

    echo "==> Staging Swift runtime stubs into $dst_dir"
    runtime_src="$RUNTIME_BASE/$arch/android"
    if [[ ! -d "$runtime_src" ]]; then
        echo "error: Swift runtime not found at $runtime_src" >&2
        echo "      Re-derive the path from your installed Swift Android SDK." >&2
        exit 1
    fi
    # Copy every runtime .so produced by the SDK *except* the
    # test/XCTest-only ones. libSheetMusicJNI.so transitively pulls
    # libswift_StringProcessing.so, lib_FoundationICU.so, etc. — listing
    # them by hand is fragile. Excluding the test libs keeps the APK lean.
    for so in "$runtime_src"/*.so; do
        name="$(basename "$so")"
        case "$name" in
            libTesting.so|libXCTest.so|lib_Testing_Foundation.so|lib_TestingInterop.so)
                continue
                ;;
        esac
        cp -L "$so" "$dst_dir/"
    done

    # libswiftCore.so links against libc++_shared.so (NDK C++ runtime),
    # which is NOT staged by the Swift Android SDK. Pull it from the NDK.
    ndk_libcxx="$NDK_LIB_BASE/$ndk_triple/libc++_shared.so"
    if [[ -f "$ndk_libcxx" ]]; then
        cp -L "$ndk_libcxx" "$dst_dir/"
    else
        echo "error: libc++_shared.so not found at $ndk_libcxx" >&2
        exit 1
    fi
done

# Stage swift-java-generated Java bindings into the Android module's
# sources. We copy rather than referencing the SwiftPM plugin output
# directly so the Android Gradle Plugin sees stable input paths under
# version control conventions, and so editor / lint tooling resolves
# imports without needing to know about .build/plugins/.../.
GEN_JAVA_SRC="$ROOT/.build/plugins/outputs/swift-java-poc/SheetMusicAndroidJNISwiftJava/destination/JExtractSwiftPlugin/src/generated/java"
GEN_JAVA_DST="$ROOT/Android/SheetMusicAndroid/src/main/java-generated"
if [[ -d "$GEN_JAVA_SRC" ]]; then
    echo
    echo "==> Staging generated Java bindings → $GEN_JAVA_DST"
    rm -rf "$GEN_JAVA_DST"
    mkdir -p "$GEN_JAVA_DST"
    cp -R "$GEN_JAVA_SRC"/. "$GEN_JAVA_DST/"
else
    echo "warning: generated Java bindings not found at $GEN_JAVA_SRC" >&2
    echo "         did the build complete cleanly?" >&2
fi

echo
echo "Done. libSheetMusicJNI.so + libSheetMusicJNISwiftJava.so + runtime staged under:"
echo "  $JNI_DIR/{arm64-v8a,x86_64}/"
echo
echo "Next: place ~/Desktop/test.mscz and run"
echo "      Scripts/android-bundle-test-score.sh"
