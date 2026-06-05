#!/usr/bin/env bash
# Pre-merge verification — run this before merging a branch into main.
#
# GitHub Actions CI is manual-only (see .github/workflows/android-audio.yml):
# the Android job runs on a macos-14 runner whose 10x billing multiplier
# exhausted the private-repo free-tier minutes. This script reproduces that
# same verification locally — plus the Apple-side `swift test` that CI never
# covered — so a green run here is the gate that CI used to be.
#
# Usage:
#   Scripts/preflight.sh              # full suite (Apple + Android)
#   Scripts/preflight.sh --apple      # Apple/SwiftPM tests only (fast)
#   Scripts/preflight.sh --android    # Android cross-compile + Kotlin tests + AAR
#
# Requirements for the Android stage mirror CLAUDE.md "Android build":
#   - swift.org Swift 6.3.2-RELEASE toolchain (TOOLCHAINS=org.swift.632202605101a)
#   - Swift Android SDK + NDK sysroot staged
#   - Java 17 + the WIRELET_PAT / gpr credentials for the wirelet Gradle plugin
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

run_apple=1
run_android=1
case "${1:-}" in
    --apple)   run_android=0 ;;
    --android) run_apple=0 ;;
    "")        ;;
    *) echo "usage: $0 [--apple|--android]" >&2; exit 2 ;;
esac

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

if [[ "$run_apple" == 1 ]]; then
    step "Apple / SwiftPM: swift build"
    swift build --package-path "$ROOT"

    step "Apple / SwiftPM: swift test"
    swift test --package-path "$ROOT"
fi

if [[ "$run_android" == 1 ]]; then
    : "${TOOLCHAINS:=org.swift.632202605101a}"
    export TOOLCHAINS

    step "Android: cross-compile JNI natives + stage bindings"
    "$ROOT/Scripts/android-build-libs.sh"

    # SwiftKitCore is an external swift-java dependency; the Android module
    # resolves it from Maven local. CI publishes it every run because its
    # runner starts with an empty ~/.m2. Locally we only need it present, and
    # re-publishing inside the SwiftPM checkout is fragile: SwiftPM marks
    # .build/checkouts/ read-only after resolve, so gradle can't write its
    # lock files (FileNotFoundException ".gradle/.../fileHashes.lock"). So:
    # skip when the artifact is already cached; otherwise make the checkout's
    # gradle cache writable and publish once.
    swiftkit_jar=(
        "$HOME"/.m2/repository/org/swift/swiftkit/swiftkit-core/*/swiftkit-core-*.jar
    )
    if [[ -e "${swiftkit_jar[0]}" ]]; then
        step "Android: SwiftKitCore already in Maven local — skipping publish"
    else
        step "Android: publish swift-java SwiftKitCore to Maven local"
        chmod -R u+w "$ROOT/.build/checkouts/swift-java/.gradle" 2>/dev/null || true
        "$ROOT/.build/checkouts/swift-java/gradlew" \
            -p "$ROOT/.build/checkouts/swift-java" \
            :SwiftKitCore:publishToMavenLocal
    fi

    step "Android: Kotlin unit tests"
    "$ROOT/Android/gradlew" -p "$ROOT/Android" \
        :SheetMusicAudioAndroid:testDebugUnitTest

    step "Android: assemble release AAR"
    "$ROOT/Android/gradlew" -p "$ROOT/Android" \
        :SheetMusicAudioAndroid:assembleRelease
fi

printf '\n\033[1;32m✓ preflight passed\033[0m\n'
