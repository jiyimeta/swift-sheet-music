#!/usr/bin/env bash
# Pre-merge verification — run this before merging a branch into main.
#
# CI (GitHub Actions, free on public runners): ci.yml runs the Apple
# build/test and the lint job on every push + PR; android-audio.yml runs
# the Android cross-compile on push to main + on demand. This script is
# the fast LOCAL gate — run it before opening a PR / merging, especially
# for Android changes, which CI only verifies post-merge to main.
#
# Usage:
#   Scripts/preflight.sh              # full suite (Apple + wasm + Android)
#   Scripts/preflight.sh --apple      # Apple/SwiftPM tests only (fast)
#   Scripts/preflight.sh --wasm       # WebAssembly: Swift tests, size gate, browser package
#   Scripts/preflight.sh --android    # Android cross-compile + Kotlin tests + AAR
#
# Requirements for the Android stage mirror docs/development/android.md:
#   - swift.org Swift 6.3.3-RELEASE toolchain (prepended to PATH by the scripts)
#   - Swift Android SDK + NDK sysroot staged
#   - Java 17 + the WIRELET_PAT / gpr credentials for the wirelet Gradle plugin
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

run_apple=1
run_wasm=1
run_android=1
case "${1:-}" in
    --apple)   run_wasm=0; run_android=0 ;;
    --wasm)    run_apple=0; run_android=0 ;;
    --android) run_apple=0; run_wasm=0 ;;
    "")        ;;
    *) echo "usage: $0 [--apple|--wasm|--android]" >&2; exit 2 ;;
esac

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

if [[ "$run_apple" == 1 ]]; then
    # Lint first: it takes seconds and CI fails the PR on it either way.
    # Missing tools are a hard error rather than a skip — a silently
    # skipped lint is how the repository drifted while `.pre-commit-config.yaml`
    # sat uninstalled.
    for tool in swiftlint swiftformat; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "error: $tool not found (brew install swiftlint swiftformat)" >&2
            exit 1
        fi
    done

    step "Apple / SwiftPM: swiftlint"
    # No path arguments — `included:` in .swiftlint.yml already names them,
    # and repeating them makes SwiftLint lint each file twice.
    (cd "$ROOT" && swiftlint lint --strict --quiet)

    # Cheap, and it catches what the type system cannot: an authored
    # `.unexpected` refusal, or an `operation` name written as a sentence.
    step "Apple / SwiftPM: error-code gates"
    "$ROOT/Scripts/gate-error-codes.sh"

    # Wider than swiftlint: .swiftlint.yml excludes Examples/Apple, but
    # the example app is formatter-clean and the pre-commit hook formats
    # it, so check it here too.
    step "Apple / SwiftPM: swiftformat"
    (cd "$ROOT" && swiftformat Sources Tests Examples Tools --lint)

    step "Apple / SwiftPM: swift build"
    swift build --package-path "$ROOT"

    step "Apple / SwiftPM: swift test"
    # Includes the always-on MSCX 2-pass idempotency gate (encode → decode →
    # encode must be byte-identical; see docs/development/mscx-idempotency.md).
    # Its corpus sweep is opt-in and is NOT run here — before a release, or
    # after any change under Sources/SheetMusicMSCX/, also run:
    #   SM_MSCX_IDEMPOTENCY_DIR=<scores dir> swift test --filter MSCXIdempotencySweep
    swift test --package-path "$ROOT"

    # The browser fixtures are recorded from this build, and nothing on the
    # Apple side used to notice when an engraving or playback change moved
    # them. The browser suite does — but only in the wasm stage below, and
    # there it reads as the two builds disagreeing rather than as a fixture
    # that stopped describing either. Checking here names the real cause, and
    # does so without a wasm toolchain. Re-record with
    # SM_WEB_FIXTURE_RECORD=1 once the engine change is confirmed intended.
    step "Apple / SwiftPM: browser fixtures are current"
    swift run --package-path "$ROOT" GenWebFixtures \
        "$ROOT/Web/sheet-music-web/test/fixtures" \
        "$ROOT/Web/sheet-music-web/assets/sheet-music.smft"
fi

if [[ "$run_wasm" == 1 ]]; then
    # Fail here rather than at the end. The browser-package stage needs these,
    # but it runs last — so in a fresh worktree the missing dependency surfaced
    # as `tsc: command not found` only after the ~6 min wasm build, the Swift
    # test run and the size gate had all passed.
    if [[ ! -d "$ROOT/Web/sheet-music-web/node_modules" ]]; then
        echo "error: Web/sheet-music-web/node_modules is missing." >&2
        echo "       run: npm install --prefix Web/sheet-music-web" >&2
        exit 1
    fi

    if TOOLCHAIN_BIN="$("$ROOT/Scripts/swift-org-toolchain.sh")"; then
        export PATH="$TOOLCHAIN_BIN:$PATH"
    fi

    # --disable-sandbox is required: PackageToJS is a SwiftPM command plugin,
    # SwiftPM sandboxes command plugins, and this one npm-installs the WASI
    # shim its test host needs. Without the flag it fails with ENOTFOUND
    # against the npm registry even when the network is fine.
    step "WebAssembly: Swift Testing on the wasm SDK"
    SWIFT_SHEET_MUSIC_WASM=1 swift package --package-path "$ROOT" \
        --disable-sandbox --swift-sdk swift-6.3.3-RELEASE_wasm \
        js test --environment node \
        --prelude "$ROOT/Scripts/package-to-js-test-prelude.mjs"

    # Before the size gate, which reports the shipped artifact's size and can
    # only do so once this has produced one.
    step "WebAssembly: build the browser bundle"
    "$ROOT/Scripts/wasm-build-web.sh"

    step "WebAssembly: size gate"
    "$ROOT/Scripts/wasm-size.sh"

    step "WebAssembly: browser package tests"
    npm --prefix "$ROOT/Web/sheet-music-web" run build
    npm --prefix "$ROOT/Web/sheet-music-web" test

    # Playwright's browsers are a 180 MB download, so this stage assumes they
    # are already installed rather than fetching them on every preflight:
    #   npx --prefix Web/sheet-music-web playwright install chromium chromium-headless-shell
    if [[ -d "$HOME/Library/Caches/ms-playwright" ]]; then
        step "WebAssembly: browser rendering tests"
        npm --prefix "$ROOT/Web/sheet-music-web" run test:e2e
    else
        step "WebAssembly: skipping rendering tests — Playwright browsers not installed"
    fi
fi

if [[ "$run_android" == 1 ]]; then
    if TOOLCHAIN_BIN="$("$ROOT/Scripts/swift-org-toolchain.sh")"; then
        export PATH="$TOOLCHAIN_BIN:$PATH"
    fi

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

    # Every published module, not just the one that transitively pulls the others in.
    # :SheetMusicAudioAndroid depends on :SheetMusicAndroid, so those two were covered
    # by the single call this replaced — :SheetMusicComposeAndroid depends on neither and
    # was therefore never built by any gate, local or CI, despite being published and
    # consumed. Extracting SheetMusicBridgeCore moved the directory its wirelet
    # `schemaPaths` scans and nothing noticed; the module is in the list for that reason.
    step "Android: assemble release AARs"
    "$ROOT/Android/gradlew" -p "$ROOT/Android" \
        :SheetMusicAudioAndroid:assembleRelease \
        :SheetMusicComposeAndroid:assembleRelease
fi

printf '\n\033[1;32m✓ preflight passed\033[0m\n'
