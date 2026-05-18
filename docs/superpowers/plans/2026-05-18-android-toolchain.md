# Android Toolchain & Portability (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cross-compile the Foundation-only subset of `swift-sheet-music` (Core / MIDI / MSCX / MusicXML / XMLTools) with the Swift 6.3 official Android SDK and get `swift test` green on an Android device.

**Architecture:** `Package.swift` becomes Swift-conditional: when the env var `SWIFT_SHEET_MUSIC_ANDROID=1` is set, the manifest assembles a reduced `targets:` / `products:` array that excludes Apple-only sub-libraries (Layout / UI / PDF / Audio / RenderPreviews). Apple-only test files (~66) are wrapped with `#if !os(Android)` so they compile on Apple platforms but vanish on Android. A new `Scripts/android-test.sh` orchestrates cross-build + `adb push` + remote `xctest` execution.

**Tech Stack:** Swift 6.3 official Android SDK (swift.org, released 2026-03-24), SwiftPM `--swift-sdk` cross-compile, Android NDK API 24+, `adb`. No Skip, no SCADE, no Gradle.

**Spec:** `docs/superpowers/specs/2026-05-18-android-toolchain-design.md`

---

### Task 1: Create worktree and branch

**Files:** none yet — worktree only

- [ ] **Step 1: Invoke the using-git-worktrees skill to create the worktree**

  Use `superpowers:using-git-worktrees` to create:
  - worktree path: `.claude/worktrees/android-toolchain`
  - branch: `feature/android-toolchain`
  - base: current `main` (the spec commit `0b52c3f` should be the tip)

  All subsequent tasks execute **inside** that worktree.

- [ ] **Step 2: Verify**

  Run from the worktree root:
  ```bash
  pwd
  git rev-parse --abbrev-ref HEAD
  git log --oneline -1
  ```
  Expected: path ends with `.claude/worktrees/android-toolchain`, branch is `feature/android-toolchain`, log shows the spec commit.

---

### Task 2: Verify Swift 6.3 Android SDK is installed

**Files:** none (environment check only)

- [ ] **Step 1: Check Swift toolchain version**

  ```bash
  swift --version
  ```
  Expected: `Swift version 6.3` or later. If older, install Swift 6.3 from <https://www.swift.org/install/> before proceeding.

- [ ] **Step 2: List installed Swift SDKs**

  ```bash
  swift sdk list
  ```
  Expected output includes a line with `aarch64-unknown-linux-android24` (and ideally also `x86_64-unknown-linux-android24` for emulator builds). If absent, install with:

  ```bash
  swift sdk install <android-sdk-url-from-swift.org-downloads>
  ```

  Pin the exact URL/checksum displayed by `swift sdk list` after install into the CLAUDE.md note added in Task 12. Do not proceed until the SDK is listed.

---

### Task 3: Add `SWIFT_SHEET_MUSIC_ANDROID` gating to Package.swift

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Replace `Package.swift` with the Swift-conditional version**

  Read the current file first, then rewrite to the structure below. The Apple-only products/targets move into separate `let` blocks that are appended only when not building for Android. Keep the doc comments intact.

  ```swift
  // swift-tools-version: 6.2

  import PackageDescription
  import Foundation

  // When SWIFT_SHEET_MUSIC_ANDROID=1 is exported, the manifest assembles a
  // reduced targets/products array that excludes Apple-only sub-libraries
  // (Layout / UI / PDF / Audio / RenderPreviews). See
  // docs/superpowers/specs/2026-05-18-android-toolchain-design.md.
  let isAndroid = ProcessInfo.processInfo.environment["SWIFT_SHEET_MUSIC_ANDROID"] == "1"

  var products: [Product] = [
      .library(name: "SheetMusic", targets: ["SheetMusic"]),
      .library(name: "SheetMusicCore", targets: ["SheetMusicCore"]),
      .library(name: "SheetMusicMSCX", targets: ["SheetMusicMSCX"]),
      .library(name: "SheetMusicMusicXML", targets: ["SheetMusicMusicXML"]),
      .library(name: "SheetMusicMIDI", targets: ["SheetMusicMIDI"]),
  ]

  var targets: [Target] = [
      .target(name: "SheetMusicCore"),
      .target(
          name: "SheetMusicXMLTools",
          dependencies: ["SheetMusicCore"],
      ),
      .target(
          name: "SheetMusicMSCX",
          dependencies: [
              "SheetMusicCore",
              "SheetMusicXMLTools",
              "ZIPFoundation",
          ],
      ),
      .target(
          name: "SheetMusicMusicXML",
          dependencies: [
              "SheetMusicCore",
              "SheetMusicXMLTools",
              "ZIPFoundation",
          ],
      ),
      .target(
          name: "SheetMusicMIDI",
          dependencies: ["SheetMusicCore"],
      ),
      .target(
          name: "SheetMusic",
          dependencies: [
              "SheetMusicCore",
              "SheetMusicMSCX",
              "SheetMusicMusicXML",
              "SheetMusicMIDI",
          ],
      ),
      .testTarget(
          name: "SheetMusicTests",
          dependencies: isAndroid ? [
              "SheetMusic",
              "SheetMusicCore",
              "SheetMusicMIDI",
              "SheetMusicMSCX",
              "SheetMusicMusicXML",
              "SheetMusicXMLTools",
              "ZIPFoundation",
          ] : [
              "SheetMusic",
              "SheetMusicCore",
              "SheetMusicMIDI",
              "SheetMusicMSCX",
              "SheetMusicMusicXML",
              "SheetMusicLayout",
              "SheetMusicUI",
              "SheetMusicAudio",
              "SheetMusicPDF",
              "SheetMusicXMLTools",
              "ZIPFoundation",
          ],
          resources: [
              .process("Resources"),
          ],
      ),
  ]

  if !isAndroid {
      products += [
          .library(name: "SheetMusicLayout", targets: ["SheetMusicLayout"]),
          .library(name: "SheetMusicUI", targets: ["SheetMusicUI"]),
          .library(name: "SheetMusicAudio", targets: ["SheetMusicAudio"]),
          .library(name: "SheetMusicPDF", targets: ["SheetMusicPDF"]),
          .executable(name: "render-previews", targets: ["RenderPreviews"]),
      ]
      targets += [
          .target(
              name: "SheetMusicLayout",
              dependencies: ["SheetMusicCore"],
              resources: [.process("Fonts/Resources")],
          ),
          .target(
              name: "SheetMusicUI",
              dependencies: ["SheetMusicCore", "SheetMusicLayout"],
          ),
          .target(
              name: "SheetMusicAudio",
              dependencies: ["SheetMusicCore", "SheetMusicMIDI"],
          ),
          .target(
              name: "SheetMusicPDF",
              dependencies: [
                  "SheetMusicCore",
                  "SheetMusicLayout",
                  "SheetMusicUI",
              ],
          ),
          .executableTarget(
              name: "RenderPreviews",
              dependencies: ["SheetMusic", "SheetMusicLayout", "SheetMusicUI"],
          ),
      ]
  }

  let package = Package(
      name: "swift-sheet-music",
      platforms: [
          .iOS(.v17),
          .macOS(.v14),
          .tvOS(.v17),
          .watchOS(.v10),
      ],
      products: products,
      dependencies: [
          .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
      ],
      targets: targets,
  )
  ```

- [ ] **Step 2: Sanity check on macOS — manifest still parses**

  ```bash
  swift package describe --type json | jq '.products[].name'
  ```
  Expected (default macOS context, env var unset): all 9 product names appear.

  ```bash
  SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe --type json | jq '.products[].name'
  ```
  Expected: only `SheetMusic`, `SheetMusicCore`, `SheetMusicMSCX`, `SheetMusicMusicXML`, `SheetMusicMIDI` appear (5 names).

- [ ] **Step 3: Commit**

  ```bash
  git add Package.swift
  git commit -m "android: gate Apple-only targets behind SWIFT_SHEET_MUSIC_ANDROID env"
  ```

---

### Task 4: Verify macOS regression — build & test still green

**Files:** none

- [ ] **Step 1: Clean build on macOS**

  ```bash
  swift package clean
  swift build
  ```
  Expected: success, no errors.

- [ ] **Step 2: Run full test suite on macOS**

  ```bash
  swift test 2>&1 | tail -30
  ```
  Expected: all suites pass — same green state as `main`.

  If any test fails, the gating in Task 3 changed something it shouldn't. Stop and diagnose before continuing.

---

### Task 5: First Android cross-compile attempt (libraries only)

**Files:** none

- [ ] **Step 1: Cross-compile**

  ```bash
  SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
      --swift-sdk aarch64-unknown-linux-android24 \
      2>&1 | tail -40
  ```
  Expected: **success** — the library targets (Core / MIDI / MSCX / MusicXML / XMLTools / SheetMusic umbrella) compile because they only depend on Foundation, which the swift.org Android SDK provides.

  If `ZIPFoundation` fails to compile on Android (it's a third-party `Foundation`-only dependency), record the exact error and stop. Resolution would require a separate fix — likely a small upstream PR or a vendored shim. The spec lists this as a known unknown.

  If `XMLParser`-using files (`SheetMusicXMLTools/XMLTreeParser.swift`) fail to compile due to a missing libxml2 link symbol, this is the second known unknown. Resolution: file an issue against swift.org's Android SDK or add a `linkerSettings:` clause. Document either way.

- [ ] **Step 2: Cross-compile with `--build-tests` (expect failures)**

  ```bash
  SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
      --swift-sdk aarch64-unknown-linux-android24 \
      --build-tests \
      2>&1 | tee /tmp/android-test-build-attempt1.log | tail -40
  ```
  Expected: **failure**. Most test files `import SwiftUI` / `import AVFoundation` / `@testable import SheetMusicLayout` etc., which don't exist on Android. This confirms the next task (gating test files) is necessary.

- [ ] **Step 3: Capture the list of failing files**

  ```bash
  grep -E "error:.*(no such module|cannot find type)" /tmp/android-test-build-attempt1.log | head -20
  ```
  This output isn't committed; it's a sanity check that the failures are exactly the modules we expect (SwiftUI, AppKit, UIKit, CoreText, CoreGraphics, AVFoundation, PDFKit, SheetMusicLayout, SheetMusicUI, SheetMusicAudio, SheetMusicPDF).

  No commit at this task. We expected `--build-tests` to fail; Task 6 fixes it.

---

### Task 6: Gate Apple-only test files with `#if !os(Android)`

**Files:**
- Modify: ~66 files under `Tests/SheetMusicTests/` (enumerated dynamically)

- [ ] **Step 1: Write `Scripts/gate-android-tests.sh`**

  Create the file with this content:

  ```bash
  #!/usr/bin/env bash
  # Wraps each test file that depends on an Apple framework or an
  # Apple-only sub-library with `#if !os(Android)` ... `#endif` so it
  # compiles on Apple platforms but vanishes on Android cross-builds.
  #
  # Idempotent: skips files that already start with `#if !os(Android)`.
  set -euo pipefail

  cd "$(dirname "$0")/.."

  PATTERN='import SwiftUI|import AVFoundation|import CoreText|import AppKit|import UIKit|import PDFKit|import CoreGraphics|@testable import SheetMusicAudio|@testable import SheetMusicUI|@testable import SheetMusicLayout|@testable import SheetMusicPDF'

  mapfile -t FILES < <(grep -rlE "$PATTERN" Tests/ --include='*.swift' | sort -u)

  echo "Found ${#FILES[@]} Apple-dependent test files."

  for f in "${FILES[@]}"; do
      first_line=$(head -n 1 "$f")
      if [[ "$first_line" == "#if !os(Android)" ]]; then
          echo "  skip (already gated): $f"
          continue
      fi
      tmp=$(mktemp)
      {
          echo "#if !os(Android)"
          cat "$f"
          echo "#endif"
      } > "$tmp"
      mv "$tmp" "$f"
      echo "  gated: $f"
  done
  ```

- [ ] **Step 2: Make it executable**

  ```bash
  chmod +x Scripts/gate-android-tests.sh
  ```

- [ ] **Step 3: Run it**

  ```bash
  ./Scripts/gate-android-tests.sh
  ```
  Expected: prints `Found 66 Apple-dependent test files.` (or close to it) and then a `gated:` line per file. None `skip`. None print errors.

- [ ] **Step 4: Verify macOS regression still green**

  Wrapping a file with `#if !os(Android)` on macOS should be a no-op (the guard is `true`, so all content stays in). Confirm:

  ```bash
  swift build && swift test 2>&1 | tail -5
  ```
  Expected: still all green.

- [ ] **Step 5: Verify Android cross-compile with tests now builds**

  ```bash
  SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
      --swift-sdk aarch64-unknown-linux-android24 \
      --build-tests \
      2>&1 | tail -10
  ```
  Expected: **success**. If any compile errors remain, they will name a specific file — gate that file too (add it manually or extend the script's grep pattern), then re-run from Step 3.

- [ ] **Step 6: Commit**

  ```bash
  git add Scripts/gate-android-tests.sh Tests/
  git commit -m "android: gate Apple-only test files with #if !os(Android)"
  ```

---

### Task 7: Write `Scripts/android-test.sh`

**Files:**
- Create: `Scripts/android-test.sh`

- [ ] **Step 1: Create the script**

  ```bash
  #!/usr/bin/env bash
  # Build the test bundle for an Android target and run it on a connected
  # device via adb. Exits with the device-side test exit code.
  #
  # Usage: Scripts/android-test.sh <target> [serial] [-- <swift-test-args>]
  #   target: aarch64 | x86_64 (mapped to *-unknown-linux-android24)
  #   serial: optional adb device serial (use when multiple devices attached)
  set -euo pipefail

  cd "$(dirname "$0")/.."

  TARGET_SHORT="${1:?usage: android-test.sh <aarch64|x86_64> [serial]}"
  case "$TARGET_SHORT" in
      aarch64) TRIPLE="aarch64-unknown-linux-android24" ;;
      x86_64)  TRIPLE="x86_64-unknown-linux-android24" ;;
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
  ```

- [ ] **Step 2: Make it executable**

  ```bash
  chmod +x Scripts/android-test.sh
  ```

- [ ] **Step 3: Quick sanity check (no device required)**

  ```bash
  ./Scripts/android-test.sh 2>&1 | head -3
  ```
  Expected: prints `usage: android-test.sh <aarch64|x86_64> [serial]` (or similar) and exits non-zero. This confirms the script parses.

- [ ] **Step 4: Commit**

  ```bash
  git add Scripts/android-test.sh
  git commit -m "android: add Scripts/android-test.sh for adb-driven test runs"
  ```

---

### Task 8: XMLParser smoke test on Android

This isolates the highest-risk dependency (libxml2-backed `XMLParser` from swift-corelibs-foundation) before trusting the full suite. If it fails here, we stop and resolve before running the rest.

**Files:**
- Create: `Tests/SheetMusicTests/AndroidSmokeTests.swift`

- [ ] **Step 1: Write the smoke test**

  ```swift
  import Foundation
  import Testing
  @testable import SheetMusicXMLTools

  @Suite("Android smoke tests")
  struct AndroidSmokeTests {
      @Test("XMLParser can parse a minimal document")
      func parseMinimalXML() throws {
          let xml = #"""
          <?xml version="1.0" encoding="UTF-8"?>
          <root>
              <child attr="value">text</child>
          </root>
          """#
          let data = Data(xml.utf8)
          let parser = try XMLTreeParser.parse(data: data)
          #expect(parser.name == "root")
          #expect(parser.children.first?.name == "child")
          #expect(parser.children.first?.attributes["attr"] == "value")
      }

      @Test("Bundle.module resolves test resources")
      func bundleModule() throws {
          // The test resource directory must be reachable on Android.
          let url = Bundle.module.url(forResource: "midi01", withExtension: "mscx")
          #expect(url != nil, "midi01.mscx must be locatable via Bundle.module")
      }
  }
  ```

  Note: the exact `XMLTreeParser.parse(data:)` signature must match the existing API in `Sources/SheetMusicMSCX/XML/XMLTreeParser.swift` — read that file first and adjust the call if the constructor is different. The test file is **not** wrapped in `#if !os(Android)` because it's deliberately for both platforms.

- [ ] **Step 2: Run on macOS first**

  ```bash
  swift test --filter AndroidSmokeTests 2>&1 | tail -10
  ```
  Expected: both `@Test` cases pass.

- [ ] **Step 3: Run on Android device**

  ```bash
  ./Scripts/android-test.sh aarch64 [serial-if-needed] -- --filter AndroidSmokeTests
  ```
  Expected: both cases pass on the Android device.

  If `parseMinimalXML` fails (likely libxml2 link error or runtime crash), stop. The fix is out of scope for this plan — file an issue, document the workaround attempt, and pause Phase 1 here.

  If `bundleModule` fails (returns nil), the resource bundle wasn't pushed correctly or `Bundle.module` lookup is broken on Android. First check `adb shell ls /data/local/tmp/swift-sheet-music-test/` for the `*_SheetMusicTests.resources` directory. If absent, fix the push logic in `Scripts/android-test.sh`.

- [ ] **Step 4: Commit**

  ```bash
  git add Tests/SheetMusicTests/AndroidSmokeTests.swift
  git commit -m "test: add Android smoke tests (XMLParser + Bundle.module)"
  ```

---

### Task 9: Full Android test run — Foundation-only suites

**Files:** none (verification only)

- [ ] **Step 1: Run the full suite on Android**

  ```bash
  ./Scripts/android-test.sh aarch64 [serial-if-needed] 2>&1 | tee /tmp/android-test-full.log | tail -30
  ```
  Expected: every test that survived gating runs. Mixed pass/fail allowed at this stage — we triage next.

- [ ] **Step 2: Categorize failures**

  Identify what failed:
  ```bash
  grep -E "(failed|FAIL|Test .* failed)" /tmp/android-test-full.log | sort -u
  ```

  For each failure, decide:
  - **Genuine Foundation parity bug on Android** (e.g., `Date` formatting differs, file URL handling differs): file a follow-up issue and gate the specific test with `#if !os(Android)` *with a comment linking the issue*. Document in CLAUDE.md if non-trivial.
  - **Test relies on an Apple-only behaviour I missed** (e.g., uses `CGFloat` semantics): gate the file. Update `Scripts/gate-android-tests.sh` pattern if useful.
  - **Real platform-portability bug in `Sources/`**: this is a finding — record it but do NOT fix outside Phase 1 scope unless it blocks `MidiExportTests`. Add a follow-up note to the spec's "Risks" section.

- [ ] **Step 3: Iterate until acceptance criterion #3 is met**

  Re-run Step 1 until all Foundation-only tests pass on Android (i.e., the suite is green). Each round, commit gating/test-fix changes with a descriptive message:

  ```bash
  git add <files>
  git commit -m "android: gate <suite> (reason)"
  ```

---

### Task 10: Verify `MidiExportTests` 12-case acceptance criterion

**Files:** none (focused verification)

- [ ] **Step 1: Run MidiExportTests only on macOS**

  ```bash
  swift test --filter MidiExportTests 2>&1 | tail -20
  ```
  Expected: 12 cases pass (`midi01` through `midi12_…`).

- [ ] **Step 2: Run MidiExportTests only on Android**

  ```bash
  ./Scripts/android-test.sh aarch64 [serial-if-needed] -- --filter MidiExportTests 2>&1 | tail -20
  ```
  Expected: same 12 cases pass on Android, identical pass/fail set as macOS.

  If any of the 12 cases fail on Android while passing on macOS, this is a Phase 1 blocker. Diagnose by comparing the produced SMF bytes — typical causes are endianness assumptions (none in this codebase, but check), file path separator handling, or floating-point determinism. Do NOT gate `MidiExportTests` to bypass — this is acceptance criterion #4.

---

### Task 11: Update CLAUDE.md with Android build instructions

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Insert a new "Android build" section**

  Add this section right after the existing "Build / test / run" section in `CLAUDE.md`:

  ````markdown
  ## Android build (Phase 1 — Foundation-only targets)

  `swift-sheet-music` cross-compiles to Android via the Swift 6.3 official
  Android SDK. Only Foundation-dependent targets are supported in this
  phase (Core / MIDI / MSCX / MusicXML / XMLTools); Layout / UI / PDF /
  Audio remain Apple-only until Phases 2-3 introduce DI abstractions.

  ### Prerequisites

  - Swift 6.3+ toolchain on the host (`swift --version`)
  - `aarch64-unknown-linux-android24` Swift SDK installed (`swift sdk list`)
  - `adb` on `$PATH` and an Android device or emulator (API ≥ 24)

  ### Building

  ```bash
  # Library targets only — fast
  SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
      --swift-sdk aarch64-unknown-linux-android24

  # With tests
  SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
      --swift-sdk aarch64-unknown-linux-android24 \
      --build-tests
  ```

  ### Running tests on a device

  ```bash
  Scripts/android-test.sh aarch64 [device-serial]
  ```

  ### Adding new tests

  Tests that import any Apple framework (`SwiftUI`, `AVFoundation`,
  `CoreText`, `CoreGraphics`, `AppKit`, `UIKit`, `PDFKit`) or that
  `@testable import` an Apple-only sub-library (`SheetMusicLayout`,
  `SheetMusicUI`, `SheetMusicAudio`, `SheetMusicPDF`) must be wrapped in
  `#if !os(Android)` ... `#endif`. Run `Scripts/gate-android-tests.sh`
  after creating new test files to apply this guard automatically.
  ````

- [ ] **Step 2: Add a "Recurring pitfalls" entry**

  Add to the existing "Recurring pitfalls" section at the bottom:

  ```markdown
  - **Android cross-compile and Package.swift**: the manifest reads
    `SWIFT_SHEET_MUSIC_ANDROID` at evaluation time. After editing
    `Package.swift`, re-run `swift package describe` both with and
    without the env var set to confirm both shapes still resolve.
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add CLAUDE.md
  git commit -m "docs: document Android Phase 1 build workflow in CLAUDE.md"
  ```

---

### Task 12: Final acceptance — fresh verification

**Files:** none

- [ ] **Step 1: Clean both build directories**

  ```bash
  swift package clean
  rm -rf .build
  ```

- [ ] **Step 2: Acceptance #1 — macOS full test green**

  ```bash
  swift build && swift test 2>&1 | tail -5
  ```
  Expected: green.

- [ ] **Step 3: Acceptance #2 — Android cross-compile (library + tests)**

  ```bash
  SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
      --swift-sdk aarch64-unknown-linux-android24 \
      --build-tests 2>&1 | tail -5
  ```
  Expected: success.

- [ ] **Step 4: Acceptance #3 — Android test run green**

  ```bash
  ./Scripts/android-test.sh aarch64 [device-serial] 2>&1 | tail -10
  ```
  Expected: all surviving Foundation-only tests pass on Android.

- [ ] **Step 5: Acceptance #4 — MidiExportTests 12-case parity**

  ```bash
  ./Scripts/android-test.sh aarch64 [device-serial] -- --filter MidiExportTests 2>&1 | tail -20
  ```
  Expected: 12 cases pass.

- [ ] **Step 6: Acceptance #5 — script reproducibility**

  Verify a single `Scripts/android-test.sh aarch64 [device-serial]` command runs the full build + push + execute cycle without manual intervention.

- [ ] **Step 7: Final commit if any cleanup needed, then merge readiness**

  ```bash
  git status   # should be clean
  git log --oneline main..HEAD
  ```
  Expected: a clean history of 5-7 focused commits ready to merge to `main` via PR or fast-forward.

---

## Notes for the executor

- **Do not silently disable failing tests on Android.** Every gate added on the Android side must be justified — either because the test legitimately requires an Apple framework (acceptable, gate without ceremony) or because it surfaces a real Foundation-parity bug (record as a finding in `docs/superpowers/specs/2026-05-18-android-toolchain-design.md` under "Risks").

- **Order matters.** Task 5 deliberately fails its second sub-step; do not "fix" it by jumping ahead to Task 6 without first running the failing build — the failure list is the evidence that gating is necessary.

- **One device is enough.** This plan does not exercise the `x86_64` emulator path; that's a stretch goal and adding it later requires only running `Scripts/android-test.sh x86_64` with an emulator attached.

- **Swift 6.3 SDK URL.** Pin the exact SDK download URL/checksum into CLAUDE.md once Task 2 confirms the local install — this lets a future developer (or CI) reproduce the toolchain.

- **No PR yet.** The merge-to-main decision belongs to the user after they review the worktree state.
