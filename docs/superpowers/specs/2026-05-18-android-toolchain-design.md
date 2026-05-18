# Android toolchain & portability (Phase 1)

Status: draft, awaiting implementation plan
Date: 2026-05-18

## Context

`swift-sheet-music` currently ships only Apple platforms (iOS 17 / macOS 14
/ tvOS 17 / watchOS 10). The end goal is to make the package usable on
Android with a Kotlin example app, replacing Apple-only dependencies
(CoreText, AVFoundation, SwiftUI, PDFKit) with platform-abstracted
implementations.

The work decomposes into four sub-projects, each with its own
spec / plan / implementation cycle:

1. **Toolchain & portability verification** (this spec)
2. Font metrics DI — extract CoreText/CoreGraphics usage from `SheetMusicLayout`
3. Audio backend DI — extract AVFoundation usage from `SheetMusicAudio`, wrap `@Observable`
4. Android example app — Kotlin Compose UI + Swift core via `Swift Java JNI Core`

This document covers only sub-project 1.

## Toolchain

Swift 6.3 (released 2026-03-24) ships the first official Swift SDK for
Android from swift.org, supported by the Swift Android Workgroup. It
includes Foundation, Dispatch, XCTest, and the `Swift Java` / `Swift Java
JNI Core` interop libraries. The SDK is installed via:

```bash
swift sdk install <swift.org-android-sdk-url>
```

and consumed by SwiftPM with `--swift-sdk aarch64-unknown-linux-android24`
(or `x86_64` for emulator builds). Prior to Swift 6.3, finagolfin's
community `swift-android-sdk` artifactbundle filled this role; it is
superseded and not used here.

Minimum Android API: **24** (Android 7.0). This matches the swift.org
SDK's baseline and covers ≥98% of active devices.

## Goal

Cross-compile the Foundation-only subset of `swift-sheet-music`
(`SheetMusicCore`, `SheetMusicMIDI`, `SheetMusicMSCX`,
`SheetMusicMusicXML`, `SheetMusicXMLTools`) with the official Swift 6.3
Android SDK, run the test bundle on an Android device or emulator, and
have **`swift test` green** there — including the 12 MuseScore-equivalence
cases in `MidiExportTests`.

## Non-goals

- Layout / UI / PDF / Audio targets on Android. These depend on
  CoreText, SwiftUI, PDFKit, AVFoundation respectively and are addressed
  in Phases 2 / 3.
- `@Observable` wrapper. Only `SheetMusicAudio/PlaybackEngine.swift`
  uses it; addressed in Phase 3.
- Android example app or any Kotlin code. Phase 4.
- Skip (skiptools) or SCADE adoption.
- Changes to `Sources/SheetMusicLayout`, `…UI`, `…PDF`, `…Audio`,
  `…/RenderPreviews`, or `Example/`. These stay untouched in Phase 1.
- CI integration. A reproducible local script is the deliverable;
  GitHub Actions wiring is a follow-up.

## Branch / worktree layout

```
worktree:  .claude/worktrees/android-toolchain  (new)
branch:    feature/android-toolchain
base:      main @ 046fd24
```

Phase 1 lives entirely in this worktree. main proceeds in parallel. The
worktree is merged to main once both Apple and Android verification
criteria are met.

## Package.swift platform gating

SwiftPM's `targets:` array has no built-in platform conditional for
target *inclusion*. Two options surveyed:

- **C-1 — manifest-level conditional inclusion (chosen).** `Package.swift`
  is Swift code; it can detect Android cross-compile context (env var
  `SWIFT_SHEET_MUSIC_ANDROID=1`, or `ProcessInfo` checking
  `Bundle.main.bundleIdentifier == nil` — env var is more explicit and
  preferred) and assemble a reduced `targets` / `products` array.

- **C-2 — leave all targets, gate file contents with `#if canImport`.**
  Rejected: more invasive (every CoreText/SwiftUI source file gains a
  top-level `#if`), error messages on Android become confusing
  ("module X has no public API"), and complicates `@testable` imports
  in `SheetMusicTests`.

C-1 implementation sketch:

```swift
let isAndroid = ProcessInfo.processInfo.environment["SWIFT_SHEET_MUSIC_ANDROID"] == "1"

let appleOnlyTargets: [Target] = isAndroid ? [] : [
    .target(name: "SheetMusicLayout", …),
    .target(name: "SheetMusicUI", …),
    .target(name: "SheetMusicAudio", …),
    .target(name: "SheetMusicPDF", …),
    .executableTarget(name: "RenderPreviews", …),
]

let appleOnlyProducts: [Product] = isAndroid ? [] : [
    .library(name: "SheetMusicLayout", …),
    .library(name: "SheetMusicUI", …),
    .library(name: "SheetMusicAudio", …),
    .library(name: "SheetMusicPDF", …),
    .executable(name: "render-previews", …),
]
```

`SheetMusicTests` keeps its `@testable import` lines for the
Apple-only sub-libraries but wraps the affected test files with
`#if canImport(SwiftUI) || canImport(AVFoundation) || canImport(CoreText)`
(per file — pick the closest) so Android compilation skips them entirely.
The test target itself remains in the targets array on Android.

The `SheetMusic` umbrella target stays unchanged — it depends only on
Core / MSCX / MusicXML / MIDI, all of which build on Android.

## Test execution mechanics

```
Scripts/android-test.sh <android-target> [device-serial]
```

Steps the script encapsulates:

1. `SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk <target> --build-tests`
   where `<target>` is `aarch64-unknown-linux-android24` for a physical
   device or `x86_64-unknown-linux-android24` for an x86 emulator.
2. Locate the resulting `swift-sheet-musicPackageTests.xctest` binary
   under `.build/<target>/debug/` and its companion `.so` deps under
   `.build/<target>/debug/`.
3. `adb [-s <serial>] push` the binary, `.so`s, and the test resource
   bundle (`swift-sheet-music_SheetMusicTests.resources/`) to
   `/data/local/tmp/swift-sheet-music-test/`.
4. `adb shell` into that directory, set `LD_LIBRARY_PATH`, and
   execute the xctest binary. Capture stdout/stderr and exit code.
5. Exit the script with the device-side exit code.

The script is a thin orchestration layer — no Gradle, no Android
Studio dependency. It expects `adb` on `$PATH` and a single connected
device or an explicit serial.

## Test-resource bundle on Android

`Tests/SheetMusicTests/Resources/` (the GPL-3.0 MuseScore fixtures and
reference MIDIs) is declared `resources: [.process("Resources")]` in the
test target. SwiftPM's `Bundle.module` resolution is implemented atop
Foundation's `Bundle` on Linux; the swift.org Android SDK inherits
that path. Verification step: a single `Bundle.module.url(forResource:)`
call in a smoke test confirms resource loading works before we trust
the rest of `MidiExportTests`.

If resource loading fails on Android (it shouldn't, but the SDK is
young), the fallback is to bundle the resources as a separate
`.tar` under `/data/local/tmp/` and override the test helper's
fixture path via an env var. This contingency is documented but not
prebuilt — only if needed.

## Acceptance criteria

Phase 1 is done when **all** of:

1. macOS `swift build` and `swift test` are still green — no
   regression. Run from a fresh clone.
2. `SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk
   aarch64-unknown-linux-android24` completes on a macOS host with the
   Swift 6.3+ Android SDK installed.
3. `Scripts/android-test.sh aarch64 <serial>` (physical arm64 device,
   API ≥24) runs the test bundle and **all Foundation-only tests pass**.
   Apple-only test files are excluded from the Android compile per the
   `#if canImport` gating; they continue to run unchanged on Apple
   platforms.
4. The 12 `MidiExportTests` cases (`midi01_basic` through `midi12_…`)
   pass on Android with identical semantic-equivalence behaviour.
5. CLAUDE.md gains a short "Android build" section pointing at the
   script and the SDK install instructions.

## Risks & open questions

- **XMLParser on Android.** swift-corelibs-foundation's `XMLParser` is
  backed by libxml2. The swift.org Android SDK includes libxml2; if a
  build/runtime mismatch surfaces in `SheetMusicMSCX`, the spec for
  Phase 1 expands to either patch the SDK shim or vendor a pure-Swift
  XML parser. Tracked as a known unknown; first concrete check is a
  trivial `XMLParser` smoke test before tackling `MidiExportTests`.

- **Foundation API parity.** Other Foundation surface used in the
  Foundation-only targets — `Data`, `URL`, `JSONDecoder` (used?),
  `FileManager`, `DateFormatter` — is expected to work but
  `MidiExportTests` exercises real fixture I/O and is the canonical
  proof.

- **ZIPFoundation on Android.** `SheetMusicMSCX` and `SheetMusicMusicXML`
  depend on `weichsel/ZIPFoundation`. The library is pure Swift over
  Foundation `Data` / `FileHandle`; expected to work but unverified.
  Build it in Android target as part of acceptance #2.

- **Test resource size.** The fixture set is ~tens of MB; `adb push`
  per test run is acceptable for a developer loop, not for CI. CI is
  a Phase 1 follow-up, not blocking.

## Out of scope follow-ups (logged for later phases)

- GitHub Actions matrix that builds Android target on every PR.
- Android emulator boot + run from CI (slow, may not be worth it
  versus device-attached local runs).
- Cross-compile from Linux host (Phase 1 verifies only macOS host;
  Linux host is symmetric and a low-cost stretch goal once macOS
  works).
- Test bundle packaging that doesn't require `adb` (e.g. via an
  Android runner app) — addressed naturally in Phase 4.
