#!/usr/bin/env bash
# Install and run Android instrumented-test APKs built by the macOS CI job.
# GitHub's macOS runners cannot boot an accelerated Android emulator, so the
# APKs are cross-compiled and assembled there, then downloaded and executed on
# an x86_64 Linux emulator. We parse the instrumentation output for the verdict
# instead of trusting the command status because `am instrument` exits 0 even
# when tests fail.
#
# Usage: Scripts/ci-run-instrumented-apks.sh <apk-dir> [log-dir]
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: Scripts/ci-run-instrumented-apks.sh <apk-dir> [log-dir]" >&2
    exit 2
fi

APK_DIR="$1"
LOG_DIR="${2:-build/instrumentation-logs}"

# These are floors rather than exact counts: adding a test must not require a
# CI edit, but a test that stops registering must fail the gate loudly.
EXPECTED_PACKAGE_FLOORS=(
    "io.github.jiyimeta.sheetmusic.test:5"
    "io.github.jiyimeta.sheetmusic.compose.test:2"
)

APKS=()
while IFS= read -r -d '' apk; do
    APKS+=("$apk")
done < <(find "$APK_DIR" -type f -name '*.apk' -print0 2>/dev/null)

if [[ ${#APKS[@]} -eq 0 ]]; then
    echo "error: no APKs found under $APK_DIR" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

for apk in "${APKS[@]}"; do
    echo "==> Installing $apk"
    adb install -r -t -g "$apk" # -t allows AGP's android:testOnly APKs.
done

INSTRUMENTATIONS=()
while IFS= read -r line; do
    component="${line#instrumentation:}"
    component="${component%% *}"
    package="${component%%/*}"
    if [[ "$package" == io.github.jiyimeta.* ]]; then
        INSTRUMENTATIONS+=("$component")
    fi
done < <(adb shell pm list instrumentation | tr -d '\r')

expectations_failed=0
for expectation in "${EXPECTED_PACKAGE_FLOORS[@]}"; do
    expected_package="${expectation%%:*}"
    found=0
    for component in "${INSTRUMENTATIONS[@]}"; do
        package="${component%%/*}"
        if [[ "$package" == "$expected_package" ]]; then
            found=1
            break
        fi
    done
    if [[ "$found" -eq 0 ]]; then
        echo "error: expected instrumentation package $expected_package was not found" >&2
        expectations_failed=1
    fi
done

for component in "${INSTRUMENTATIONS[@]}"; do
    package="${component%%/*}"
    expected=0
    for expectation in "${EXPECTED_PACKAGE_FLOORS[@]}"; do
        expected_package="${expectation%%:*}"
        if [[ "$package" == "$expected_package" ]]; then
            expected=1
            break
        fi
    done
    if [[ "$expected" -eq 0 ]]; then
        echo "error: unexpected instrumentation package $package ($component)" >&2
        expectations_failed=1
    fi
done

if [[ "$expectations_failed" -ne 0 ]]; then
    exit 1
fi

SUMMARIES=()
failed=0

for component in "${INSTRUMENTATIONS[@]}"; do
    package="${component%%/*}"
    log_file="$LOG_DIR/$package.log"
    minimum_tests=0
    for expectation in "${EXPECTED_PACKAGE_FLOORS[@]}"; do
        expected_package="${expectation%%:*}"
        if [[ "$package" == "$expected_package" ]]; then
            minimum_tests="${expectation##*:}"
            break
        fi
    done

    echo "==> Running $component"
    set +e
    adb shell am instrument -w "$component" 2>&1 | tr -d '\r' | tee "$log_file"
    set -e

    reasons=()
    if grep -q 'FAILURES!!!' "$log_file"; then
        reasons+=("reported FAILURES!!!")
    fi
    if grep -Eq 'Process crashed|INSTRUMENTATION_ABORTED' "$log_file"; then
        reasons+=("reported a crash or aborted instrumentation")
    fi

    ok_count=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^OK[[:space:]]+\(([0-9]+)[[:space:]]+tests?\)$ ]]; then
            ok_count="${BASH_REMATCH[1]}"
        fi
    done < "$log_file"

    if [[ -z "$ok_count" ]]; then
        reasons+=("missing final OK test count")
    elif [[ "$ok_count" -eq 0 ]]; then
        reasons+=("ran zero tests")
    elif [[ "$ok_count" -lt "$minimum_tests" ]]; then
        reasons+=("ran $ok_count tests, below floor $minimum_tests")
    fi

    if [[ ${#reasons[@]} -eq 0 ]]; then
        SUMMARIES+=("$component: PASS ($ok_count tests)")
    else
        failed=1
        reason_text="${reasons[0]}"
        for reason in "${reasons[@]:1}"; do
            reason_text="$reason_text; $reason"
        done
        SUMMARIES+=("$component: FAIL ($reason_text)")
    fi
done

if [[ "$failed" -ne 0 ]]; then
    # Capture logcat only on failure: native/JNI crash details live there, while
    # retaining it for passing runs would add a large, noisy artifact.
    if ! adb logcat -d > "$LOG_DIR/logcat.txt"; then
        echo "warning: failed to capture logcat" >&2
    fi
fi

echo
echo "Instrumentation summary:"
printf '  %s\n' "${SUMMARIES[@]}"

exit "$failed"
