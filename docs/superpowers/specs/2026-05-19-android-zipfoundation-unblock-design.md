# Android ZIPFoundation cross-compile unblock — design

Date: 2026-05-19
Phase: 1.5 (Android port roadmap)
Branch: `feature/android-toolchain` (continues from Phase 1)

## Goal

Re-enable `.mscz` and `.mxl` read **and** write on Android cross-compile,
removing the `#if !os(Android)` guards introduced in Phase 1 for
`MSCZReader`, `MSCZWriter`, and `MXLReader`. Restore the matching tests
(`MSCZReaderTests`, `MXLTestBuilder`, and any mscz-fixture-using
`MidiExportTests` cases) to the Android test run.

Out of scope: Phase 2 (Layout DI), Phase 3 (Audio DI), Phase 4 (Kotlin
Compose), `os.Logger` Android compatibility, non-ASCII filename pre-commit
detection.

## Why this is blocked today

ZIPFoundation 0.9.20 (currently pinned in `Package.swift`) fails Android
cross-compile from a macOS host for two independent reasons:

1. **Source-level**: Bionic does not re-export libc symbols through
   `import Foundation` the way Darwin / Glibc / ucrt do. References to
   `stat`, `fopen`, `S_IFMT`, `mode_t`, etc. fail to resolve.
2. **Manifest-level**: ZIPFoundation's `Package.swift` declares its
   `CZLib` system-library target only inside
   `#if !canImport(Compression)`. SwiftPM evaluates the manifest with
   the **host** compiler — on macOS that branch is never taken, so
   `CZLib` is never declared and the sources' `import CZlib` fails
   with `error: no such module 'CZlib'`.

Cause 1 was fixed upstream by PR #380, merged to `weichsel/ZIPFoundation`
`development` on 2026-05-17 (Bionic import shim + Bionic-strict pointer
signatures + Apple-only `setSymlinkPermissions` guard). Cause 2 remains
unaddressed on `development`.

Phase 1 worked around both causes by gating `MSCZReader` / `MSCZWriter`
/ `MXLReader` with `#if !os(Android)` and removing ZIPFoundation from
the Android-side Package shape entirely.

## Approach: fork the upstream and patch the manifest

Three artefacts move together:

### 1. `jiyimeta/ZIPFoundation` fork

Fork `weichsel/ZIPFoundation`, branch off `development` HEAD (which
contains PR #380's Bionic source fixes), make a single commit on
`android-manifest-fix` that rewrites `Package.swift` to declare `CZLib`
unconditionally and gate dependency/linker settings by **target**
platform via `.when(platforms:)`.

The patched manifest:

```swift
// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "ZIPFoundation",
    platforms: [
        .macOS(.v10_11), .iOS(.v9), .tvOS(.v9), .watchOS(.v2)
    ],
    products: [
        .library(name: "ZIPFoundation", targets: ["ZIPFoundation"])
    ],
    targets: [
        .systemLibrary(
            name: "CZLib",
            pkgConfig: "zlib",
            providers: [.brew(["zlib"]), .apt(["zlib"])]
        ),
        .target(
            name: "ZIPFoundation",
            dependencies: [
                .target(
                    name: "CZLib",
                    condition: .when(platforms: [.linux, .android, .windows, .openbsd])
                )
            ],
            cSettings: [
                .define("_GNU_SOURCE", to: "1",
                    .when(platforms: [.linux, .android]))
            ],
            linkerSettings: [
                .linkedLibrary("z",
                    .when(platforms: [.linux, .android]))
            ]
        ),
        .testTarget(name: "ZIPFoundationTests", dependencies: ["ZIPFoundation"])
    ],
    swiftLanguageVersions: [.v4, .v4_2, .v5]
)
```

Why this works where the current manifest does not:

- `.systemLibrary` is declared **unconditionally**, so SwiftPM always
  knows the target exists regardless of which host evaluates the
  manifest.
- The `Target.Dependency` and `BuildSettingCondition` `.when(platforms:)`
  forms are evaluated against the **build target**, not the host.
  When cross-compiling for Android from macOS, SwiftPM links `-l z`
  and resolves the `CZLib` dependency only for Android, while on
  Apple targets the dependency is skipped and `CZLib`'s declaration
  is dormant (no `brew install zlib` requirement, no impact on the
  produced binary).
- `tools-version` is raised to 5.3 (released 2020-09) to admit the
  `Target.Dependency.target(name:condition:)` form. ZIPFoundation
  currently declares 5.0; the bump is a meaningful but mild floor
  increase.

### 2. Upstream PR

From the same `android-manifest-fix` branch, open a PR to
`weichsel/ZIPFoundation:development` titled
"Fix manifest evaluation for cross-compile: declare CZLib
unconditionally, gate dep/linker by target platform". The description:

- Explains the host-evaluated `#if canImport(Compression)` bug, citing
  the `error: no such module 'CZlib'` failure mode.
- Notes that PR #380 (Bionic imports) is a prerequisite already in
  `development`.
- Shows three `swift build` results: macOS native (regression check),
  Linux native (regression check), Android cross-compile from macOS
  (`--swift-sdk aarch64-unknown-linux-android28`).
- Calls out the `tools-version` bump 5.0 → 5.3 with rationale.

### 3. `swift-sheet-music` changes

In `Package.swift`:

- Swap the dependency from `weichsel/ZIPFoundation` `exact: 0.9.20`
  to `jiyimeta/ZIPFoundation` `revision: "<sha>"` (the HEAD of
  `android-manifest-fix` after the manifest commit; SHA captured at
  implementation time).
- Remove the `isAndroid ? ... : ...` ternaries from the Android-side
  target dependencies — `SheetMusicMSCX`, `SheetMusicMusicXML`, and
  `SheetMusicTests` regain ZIPFoundation unconditionally, since the
  patched fork compiles for Android.
- Keep the `SWIFT_SHEET_MUSIC_ANDROID` env split for the Apple-only
  products (Layout / UI / Audio / PDF / RenderPreviews) — that gating
  is unrelated to Phase 1.5.

In sources:

- Remove `#if !os(Android)` / `#endif` wrappers from
  `Sources/SheetMusicMSCX/MSCZReader.swift`,
  `Sources/SheetMusicMSCX/MSCZWriter.swift`, and
  `Sources/SheetMusicMusicXML/MXL/MXLReader.swift`.

In tests:

- Remove `#if !os(Android)` from
  `Tests/SheetMusicTests/MSCZReaderTests.swift` and
  `Tests/SheetMusicTests/Helpers/MXLTestBuilder.swift`.

In scripts:

- Update `Scripts/gate-android-tests.sh` so it no longer treats
  `import ZIPFoundation` as an Apple-only marker.

In docs:

- Refresh the "Format support matrix on Android" section in
  `CLAUDE.md` (worktree copy) to state that `.mscz` and `.mxl` are
  fully supported on Android in Phase 1.5, and note the fork pin.

## Why revision pin, not tag

The fork is a temporary patch intended to be discarded when upstream
ships the fix. A tag would imply a stable release artefact; a revision
SHA communicates "in-flight fork pin, expect it to go away" and
sidesteps re-tagging if PR review forces additional manifest changes.
`Package.resolved` records the resolved SHA in both forms, so
reproducibility across CI / other dev machines is identical.

The branch `android-manifest-fix` must remain pushed on the fork (the
revision must be reachable from a branch ref). Delete the branch only
in the cleanup step below.

## Cleanup / fork-drop trigger

When upstream cuts a release that contains the manifest fix (anticipated
0.9.21 or later, depending on what other work goes in alongside):

1. Change `swift-sheet-music`'s `Package.swift` dependency back to
   `weichsel/ZIPFoundation` `exact: <released-version>`.
2. Re-run `swift test` (macOS) and `Scripts/android-test.sh aarch64`
   to confirm no regression.
3. Archive `jiyimeta/ZIPFoundation` on GitHub.
4. Update or remove this spec / the project memory entry
   `project_android_port_roadmap.md` to reflect Phase 1.5 closure.

Until then, the fork stays read/active.

## Testing strategy

1. **macOS host regression**: `swift test` fully green
   (current baseline 1097 tests / 191 suites). Verify `Package.resolved`
   now references `jiyimeta/ZIPFoundation` with the chosen revision.
2. **Apple Example app builds**: per
   `feedback_example_app_outside_swiftpm.md`, rebuild iOS Simulator
   and Mac schemes via `xcodebuild` to confirm Package resolution
   succeeds with the fork URL.
3. **Android cross-compile build**:
   ```
   SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
       --swift-sdk aarch64-unknown-linux-android28 \
       --build-tests
   ```
   Linker invocation in build log should include `-l z`. Module
   resolution should no longer error on `CZlib`.
4. **Android emulator test run**: `Scripts/android-test.sh aarch64`
   green. Test count rises above the Phase 1 baseline (679 tests /
   116 suites) by the number of `MSCZReaderTests` / mscz-fixture
   `MidiExportTests` / `MXLTestBuilder`-using cases re-enabled.
5. **Upstream PR validation**: paste a condensed transcript of (1),
   a Linux native `swift build` (run in a container or CI), and
   (3) into the PR description.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Upstream rejects `tools-version` bump 5.0 → 5.3 | The PR description leads with the rationale (`.when(platforms:)` on `Target.Dependency` is 5.3+). If review pushes back, fallback is to keep the conditional `cSettings`/`linkerSettings` but route the CZLib dependency through a separate `.target` wrapper inside the manifest; this adds indirection without bumping tools-version. Spec stays in place either way — the fork SHA just moves. |
| NDK `libz.so` API-level mismatch | NDK 28.2 sysroot ships per-API `libz.so` for 21–35 under `usr/lib/<triple>/<api>/`. `--swift-sdk aarch64-unknown-linux-android28` selects API 28, matching `Scripts/android-test.sh`'s default. Other API levels are present should the script change. |
| Upstream PR sits in review for weeks | Revision-pinned fork is stable indefinitely. Phase 1.5 can ship and Phase 2 (Layout DI) can proceed in parallel. Only the cleanup step waits on upstream release. |
| `_GNU_SOURCE` define interacts badly with Bionic | Existing 0.9.20 already sets `_GNU_SOURCE` for Linux non-Apple builds; PR #380 was validated with this define in scope. No new exposure introduced by Phase 1.5. |
| The fork's `android-manifest-fix` branch is accidentally deleted before cleanup | The branch is the only ref keeping the pinned revision reachable. Document in the spec / fork README "do not delete this branch until cleanup step 3". Optionally also tag the same SHA as `pinned-do-not-delete` as a belt-and-braces ref. |

## Acceptance criteria

Phase 1.5 is complete when **all** of the following hold:

- `Package.swift` depends on `jiyimeta/ZIPFoundation` at a specific
  revision and contains no `isAndroid` branch for ZIPFoundation.
- `#if !os(Android)` is absent from `MSCZReader`, `MSCZWriter`,
  `MXLReader`, `MSCZReaderTests`, and `MXLTestBuilder`.
- `swift test` (macOS) is fully green.
- `Scripts/android-test.sh aarch64` is fully green, with a test count
  above the Phase 1 baseline.
- Both the iOS Simulator and the Mac `xcodebuild` schemes for the
  Example app build clean.
- An upstream PR to `weichsel/ZIPFoundation:development` is open with
  the validation transcripts attached.
- `CLAUDE.md` (and the project memory entry for the Android port
  roadmap) reflects the new Phase 1.5 state.

The follow-up cleanup (fork drop, dependency reset to upstream
release) is a separate small task tracked under the roadmap memory;
it is **not** required for Phase 1.5 sign-off.
