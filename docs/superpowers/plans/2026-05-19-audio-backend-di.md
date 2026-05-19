# Audio backend DI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `SheetMusicAudio` into a Foundation-only `SheetMusicAudioCore` target and an Apple-only `SheetMusicAudioApple` target, with `SheetMusicAudio` becoming a thin umbrella that re-exports both on Apple and only `Core` on Android — so the Android Swift 6.3 SDK can cross-compile the Foundation-only half while every existing Apple consumer keeps writing `import SheetMusicAudio`.

**Architecture:** Apple consumers see no API change. Android sees Foundation-only types (`PlaybackTimeline`, `MetronomeBeat`, `MixerChannel`, `LoopRange`, `PlaybackState`, `AudioFileFormat`, etc.); `PlaybackEngine` / writers / sequencers live behind a target boundary that does not exist in the Android build graph. No protocol seam yet — Phase 4 will decide that when an Android backend is added.

**Tech Stack:** Swift 6.2 manifest, Swift 6.3.2 toolchain, SwiftPM target boundaries, `@_exported import`, `#if canImport(AVFoundation)`, `SWIFT_SHEET_MUSIC_ANDROID=1` manifest flag.

---

## Worktree

This plan executes in `.claude/worktrees/audio-backend-di/` on branch `worktree-audio-backend-di`. The spec named `feature/audio-backend-di`; the EnterWorktree tool chose `worktree-audio-backend-di`. **Do not rename** — keep the branch as-is to match the worktree tool's lifecycle. At merge time, the squash/merge target stays `main`.

## File structure (post-Plan)

```
Sources/
  SheetMusicAudio/                 1 file (umbrella)
    SheetMusicAudio.swift           # @_exported imports (umbrella)

  SheetMusicAudioCore/             10 files (Foundation-only)
    PlaybackTimeline.swift          # moved
    MetronomeBeat.swift             # moved
    GMInstrument.swift              # moved
    MixerChannel.swift              # moved
    SoundfontResolver.swift         # moved
    LoopRange.swift                 # NEW — extracted from PlaybackEngine.swift
    PlaybackState.swift             # NEW — extracted from PlaybackEngine.swift
    Export/
      AudioFileFormat.swift         # moved
      AudioExportError.swift        # moved
      AudioExportRange.swift        # moved

  SheetMusicAudioApple/             7 files (AVFoundation-only)
    PlaybackEngine.swift            # moved; LoopRange + PlaybackState removed
    PlaybackEngine+Export.swift     # moved
    PlaybackEngine+Mixer.swift      # moved
    MetronomeController.swift       # moved
    MIDISynthBuilder.swift          # moved
    Export/
      AudioExportWriter.swift       # moved
      AudioFileExporter.swift       # moved
```

Old `Sources/SheetMusicAudio/Export/` and `Sources/SheetMusicAudio/*.swift` (other than the umbrella file) cease to exist. The directory itself remains with one Swift file + `README.md` (also rewritten).

---

## Task 1: Baseline + audit

**Files:**
- Read: `Package.swift`
- Read: `Sources/SheetMusicAudio/PlaybackEngine.swift:29-47`
- Inspect: `Tests/SheetMusicTests/*Audio*.swift`, `Tests/SheetMusicTests/MixerChannelTests.swift`, `Tests/SheetMusicTests/PlaybackTimelineTests.swift`

- [ ] **Step 1: Verify worktree branch and clean tree**

Run:
```bash
git status --short
git branch --show-current
git log -1 --oneline
```
Expected: clean tree, branch `worktree-audio-backend-di`, HEAD `ba318fd docs(android): add Phase 3 Audio backend DI spec`.

- [ ] **Step 2: macOS baseline test run**

Run:
```bash
swift build
swift test 2>&1 | tail -5
```
Expected: build succeeds, `1119` tests pass (or whatever the current green baseline is — record the exact count for comparison in T7).

- [ ] **Step 3: Android baseline cross-compile (pre-change)**

Run:
```bash
export TOOLCHAINS=org.swift.632202605101a
swift --version | head -1
SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28 2>&1 | tail -10
```
Expected: banner contains `swift-6.3.2-RELEASE`; build succeeds (Phase 1.6 + Phase 2 already pass).

- [ ] **Step 4: Grep for hidden Apple imports inside the to-be-Core files**

Run:
```bash
grep -nE 'import (AVFoundation|AVAudio|UIKit|AppKit|CoreGraphics|CoreText)' \
  Sources/SheetMusicAudio/PlaybackTimeline.swift \
  Sources/SheetMusicAudio/MetronomeBeat.swift \
  Sources/SheetMusicAudio/GMInstrument.swift \
  Sources/SheetMusicAudio/MixerChannel.swift \
  Sources/SheetMusicAudio/SoundfontResolver.swift \
  Sources/SheetMusicAudio/Export/AudioFileFormat.swift \
  Sources/SheetMusicAudio/Export/AudioExportError.swift \
  Sources/SheetMusicAudio/Export/AudioExportRange.swift
```
Expected: no matches (only doc-comment mentions of `AVAudioSequencer` etc., which are fine).

- [ ] **Step 5: Identify tests that need `@testable import SheetMusicAudioApple`**

Run:
```bash
grep -lE 'PlaybackEngine|MetronomeController|MIDISynthBuilder|AudioExportWriter|AudioFileExporter|postProcessForMIDISynth|setStateForExport|exportTimeline\(' \
  Tests/SheetMusicTests/*.swift
```
Expected: a short list (e.g. `AudioFileExporterTests.swift`, `MidiImportRoundTripTests.swift`, etc.). Record it — these files will get the `@testable import SheetMusicAudioApple` line in T6.

- [ ] **Step 6: Confirm no commit yet**

Run: `git status --short`
Expected: empty (no edits yet — this task is read-only).

No commit at the end of this task. T2 onwards starts producing commits.

---

## Task 2: Create empty target directories + extract `LoopRange` / `PlaybackState`

This is the smallest atomic refactor that still produces a green build before any cross-target move. `LoopRange` and `PlaybackState` live in `PlaybackEngine.swift` today; extracting them into separate Foundation-only files (still under `Sources/SheetMusicAudio/`) is a no-op for the build graph and gives us two pre-staged Foundation-only files ready to migrate in T3.

**Files:**
- Create: `Sources/SheetMusicAudio/LoopRange.swift`
- Create: `Sources/SheetMusicAudio/PlaybackState.swift`
- Modify: `Sources/SheetMusicAudio/PlaybackEngine.swift:29-47`

- [ ] **Step 1: Create `LoopRange.swift`**

```swift
// Sources/SheetMusicAudio/LoopRange.swift
import Foundation

/// Half-open tick range `[startTick, endTick)` the engine should
/// loop while playing. Tick-based rather than cursor-based because
/// `setLoop(from:throughEndOf:)` wraps at an item's offset, which
/// rarely coincides with a `ScoreCursor` column. Hosts that want a
/// cursor for the boundaries can resolve via
/// `PlaybackTimeline.frame(atTick:)`.
public struct LoopRange: Sendable, Equatable {
    public let startTick: Int
    public let endTick: Int

    public init(startTick: Int, endTick: Int) {
        self.startTick = startTick
        self.endTick = endTick
    }
}
```

- [ ] **Step 2: Create `PlaybackState.swift`**

```swift
// Sources/SheetMusicAudio/PlaybackState.swift
import Foundation

/// State machine for full-score playback. Drives any UI that
/// needs to switch between play / pause icons.
public enum PlaybackState: Sendable, Equatable {
    case stopped, playing, paused, exporting
}
```

- [ ] **Step 3: Remove the original declarations from `PlaybackEngine.swift`**

Open `Sources/SheetMusicAudio/PlaybackEngine.swift` and delete lines 27-47 (the `PlaybackState` enum, its doc comment block at 27-28, and the `LoopRange` struct with its doc comment at 33-47). The file's leading `import AVFoundation` / `import Foundation` / `import SheetMusicCore` / `import SheetMusicMIDI` block stays untouched.

After deletion, line 27 should be the `@MainActor` attribute that originally sat at line 49, and the file should still read top-to-bottom as a single class definition with no orphan doc comments.

- [ ] **Step 4: Verify build is still green**

Run:
```bash
swift build 2>&1 | tail -10
swift test --filter PlaybackTimelineTests 2>&1 | tail -5
```
Expected: build succeeds, `PlaybackTimelineTests` passes. No semantic change.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudio/LoopRange.swift \
        Sources/SheetMusicAudio/PlaybackState.swift \
        Sources/SheetMusicAudio/PlaybackEngine.swift
git commit -m "audio: extract LoopRange and PlaybackState into separate files

Pre-Phase-3 refactor: pull the two Foundation-only value types out of
PlaybackEngine.swift so the upcoming SheetMusicAudioCore target can
take them without dragging AVFoundation along. No behavior change."
```

---

## Task 3: Create `SheetMusicAudioCore` target and move Foundation-only files

**Files:**
- Modify: `Package.swift` (add `SheetMusicAudioCore` target + product)
- Move: 10 files from `Sources/SheetMusicAudio/` → `Sources/SheetMusicAudioCore/`

- [ ] **Step 1: Create the new source directory**

Run:
```bash
mkdir -p Sources/SheetMusicAudioCore/Export
```

- [ ] **Step 2: Move the 10 Foundation-only files with `git mv`**

Run each line as its own Bash call (per repo discipline against compound `;` chains):

```bash
git mv Sources/SheetMusicAudio/PlaybackTimeline.swift     Sources/SheetMusicAudioCore/PlaybackTimeline.swift
```
```bash
git mv Sources/SheetMusicAudio/MetronomeBeat.swift        Sources/SheetMusicAudioCore/MetronomeBeat.swift
```
```bash
git mv Sources/SheetMusicAudio/GMInstrument.swift         Sources/SheetMusicAudioCore/GMInstrument.swift
```
```bash
git mv Sources/SheetMusicAudio/MixerChannel.swift         Sources/SheetMusicAudioCore/MixerChannel.swift
```
```bash
git mv Sources/SheetMusicAudio/SoundfontResolver.swift    Sources/SheetMusicAudioCore/SoundfontResolver.swift
```
```bash
git mv Sources/SheetMusicAudio/LoopRange.swift            Sources/SheetMusicAudioCore/LoopRange.swift
```
```bash
git mv Sources/SheetMusicAudio/PlaybackState.swift        Sources/SheetMusicAudioCore/PlaybackState.swift
```
```bash
git mv Sources/SheetMusicAudio/Export/AudioFileFormat.swift   Sources/SheetMusicAudioCore/Export/AudioFileFormat.swift
```
```bash
git mv Sources/SheetMusicAudio/Export/AudioExportError.swift  Sources/SheetMusicAudioCore/Export/AudioExportError.swift
```
```bash
git mv Sources/SheetMusicAudio/Export/AudioExportRange.swift  Sources/SheetMusicAudioCore/Export/AudioExportRange.swift
```

- [ ] **Step 3: Update `Package.swift` — add `SheetMusicAudioCore`**

In the `var products: [Product] = [ ... ]` block (currently ending at the line `.library(name: "SheetMusicLayout", targets: ["SheetMusicLayout"]),`), append `SheetMusicAudioCore` as an always-on product:

```swift
var products: [Product] = [
    .library(name: "SheetMusic", targets: ["SheetMusic"]),
    .library(name: "SheetMusicCore", targets: ["SheetMusicCore"]),
    .library(name: "SheetMusicMSCX", targets: ["SheetMusicMSCX"]),
    .library(name: "SheetMusicMusicXML", targets: ["SheetMusicMusicXML"]),
    .library(name: "SheetMusicMIDI", targets: ["SheetMusicMIDI"]),
    .library(name: "SheetMusicLayout", targets: ["SheetMusicLayout"]),
    .library(name: "SheetMusicAudioCore", targets: ["SheetMusicAudioCore"]),
]
```

In the `var targets: [Target] = [ ... ]` block, immediately before the `.target(name: "SheetMusic", ...)` entry, insert:

```swift
    .target(
        name: "SheetMusicAudioCore",
        dependencies: ["SheetMusicCore", "SheetMusicMIDI"],
    ),
```

- [ ] **Step 4: Update the Android branch of the test target's `dependencies` array**

In `Package.swift`, locate the `.testTarget(name: "SheetMusicTests", dependencies: isAndroid ? [ ... ] : [ ... ])` block. In the **Android** branch (the first arm of the ternary), add `"SheetMusicAudioCore"` alongside the existing Foundation-only entries:

```swift
        dependencies: isAndroid ? [
            "SheetMusic",
            "SheetMusicCore",
            "SheetMusicMIDI",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicLayout",
            "SheetMusicAudioCore",
            "SheetMusicXMLTools",
            "SheetMusicZip",
        ] : [
```

Leave the Apple branch (non-Android) **unchanged for now** — `SheetMusicAudioCore` will reach it transitively through the umbrella `SheetMusicAudio` dependency, which still exists.

- [ ] **Step 5: Update existing `SheetMusicAudio` target to depend on the new Core**

Inside the `if !isAndroid { ... targets += [ ... ] }` block, change the `.target(name: "SheetMusicAudio", ...)` entry to add `SheetMusicAudioCore`:

```swift
        .target(
            name: "SheetMusicAudio",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicMIDI",
                "SheetMusicAudioCore",
            ],
        ),
```

(We'll prune `SheetMusicCore` / `SheetMusicMIDI` from this list in T5 once it becomes the umbrella, but leaving them now is harmless.)

- [ ] **Step 6: Verify macOS build still passes after the file moves**

Run:
```bash
swift build 2>&1 | tail -10
```
Expected: build succeeds. The Apple targets still see the moved types because `SheetMusicAudio` now depends on `SheetMusicAudioCore` (which exports them). No `@_exported` needed yet because tests / Example don't `@testable import` the new module.

- [ ] **Step 7: Run macOS tests**

Run:
```bash
swift test 2>&1 | tail -5
```
Expected: same green count as Task 1 baseline. If `@testable` access fails on `PlaybackTimeline` internals (e.g. `MetronomeBeatTests` uses an internal initializer), that signals the test target needs to also `@testable import SheetMusicAudioCore` — but those tests currently only touch public surface, so the build should remain green.

- [ ] **Step 8: Verify Android cross-compile picks up `SheetMusicAudioCore`**

Run:
```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28 2>&1 | tail -10
```
Expected: build succeeds. `SheetMusicAudioCore` compiles for Android because all 10 files are Foundation-only.

- [ ] **Step 9: Verify `swift package describe` graph on Android**

Run:
```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe --type json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("\n".join(sorted(t["name"] for t in d["targets"])))'
```
Expected output (alphabetical):
```
SheetMusic
SheetMusicAudioCore
SheetMusicCore
SheetMusicLayout
SheetMusicMIDI
SheetMusicMSCX
SheetMusicMusicXML
SheetMusicTests
SheetMusicXMLTools
SheetMusicZip
```
No `SheetMusicAudio`, `SheetMusicAudioApple`, `SheetMusicLayoutApple`, `SheetMusicUI`, `SheetMusicPDF`, `RenderPreviews`.

- [ ] **Step 10: Commit**

```bash
git add Sources/SheetMusicAudioCore Package.swift
git rm -r --cached Sources/SheetMusicAudio/Export 2>/dev/null || true
git add Sources/SheetMusicAudio
git commit -m "audio: introduce SheetMusicAudioCore Foundation-only target

Phase 3 step 1/3 of the SheetMusicAudio split. Moves 10 Foundation-only
files (PlaybackTimeline, MetronomeBeat, GMInstrument, MixerChannel,
SoundfontResolver, LoopRange, PlaybackState, AudioFileFormat,
AudioExportError, AudioExportRange) into a dedicated target so the
Android cross-compile can pick them up. SheetMusicAudio remains the
Apple-only library and still exports these types transitively."
```

---

## Task 4: Create `SheetMusicAudioApple` target and move Apple-only files

**Files:**
- Modify: `Package.swift`
- Move: 7 files from `Sources/SheetMusicAudio/` → `Sources/SheetMusicAudioApple/`

- [ ] **Step 1: Create the new source directory**

Run:
```bash
mkdir -p Sources/SheetMusicAudioApple/Export
```

- [ ] **Step 2: Move the 7 Apple-only files with `git mv`**

```bash
git mv Sources/SheetMusicAudio/PlaybackEngine.swift          Sources/SheetMusicAudioApple/PlaybackEngine.swift
```
```bash
git mv Sources/SheetMusicAudio/PlaybackEngine+Export.swift   Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift
```
```bash
git mv Sources/SheetMusicAudio/PlaybackEngine+Mixer.swift    Sources/SheetMusicAudioApple/PlaybackEngine+Mixer.swift
```
```bash
git mv Sources/SheetMusicAudio/MetronomeController.swift     Sources/SheetMusicAudioApple/MetronomeController.swift
```
```bash
git mv Sources/SheetMusicAudio/MIDISynthBuilder.swift        Sources/SheetMusicAudioApple/MIDISynthBuilder.swift
```
```bash
git mv Sources/SheetMusicAudio/Export/AudioExportWriter.swift   Sources/SheetMusicAudioApple/Export/AudioExportWriter.swift
```
```bash
git mv Sources/SheetMusicAudio/Export/AudioFileExporter.swift   Sources/SheetMusicAudioApple/Export/AudioFileExporter.swift
```

- [ ] **Step 3: Add `import SheetMusicAudioCore` to the moved Apple files**

The 7 Apple files now sit in a separate target and need to import `SheetMusicAudioCore` to keep seeing `PlaybackTimeline`, `MetronomeBeat`, `LoopRange`, `PlaybackState`, `MixerChannel`, `SoundfontResolver`, `GMInstrument`, `AudioFileFormat`, `AudioExportError`, `AudioExportRange`.

For each of these 7 files, add the line `import SheetMusicAudioCore` immediately after the existing `import SheetMusicMIDI` line (or after `import SheetMusicCore` if `SheetMusicMIDI` isn't imported):

```swift
import SheetMusicCore
import SheetMusicMIDI
import SheetMusicAudioCore   // ← add this
```

The seven files are:
- `Sources/SheetMusicAudioApple/PlaybackEngine.swift`
- `Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift`
- `Sources/SheetMusicAudioApple/PlaybackEngine+Mixer.swift`
- `Sources/SheetMusicAudioApple/MetronomeController.swift`
- `Sources/SheetMusicAudioApple/MIDISynthBuilder.swift`
- `Sources/SheetMusicAudioApple/Export/AudioExportWriter.swift`
- `Sources/SheetMusicAudioApple/Export/AudioFileExporter.swift`

Use `grep -n '^import ' Sources/SheetMusicAudioApple/...` first to find the exact existing import block for each file.

- [ ] **Step 4: Update `Package.swift` — declare `SheetMusicAudioApple` as Apple-only**

Inside the `if !isAndroid { products += [ ... ] }` block, add `SheetMusicAudioApple` as a library product (immediately after the existing `SheetMusicAudio` product):

```swift
    products += [
        .library(name: "SheetMusicLayoutApple", targets: ["SheetMusicLayoutApple"]),
        .library(name: "SheetMusicUI", targets: ["SheetMusicUI"]),
        .library(name: "SheetMusicAudio", targets: ["SheetMusicAudio"]),
        .library(name: "SheetMusicAudioApple", targets: ["SheetMusicAudioApple"]),
        .library(name: "SheetMusicPDF", targets: ["SheetMusicPDF"]),
        .executable(name: "render-previews", targets: ["RenderPreviews"]),
    ]
```

Inside the `if !isAndroid { targets += [ ... ] }` block, add the `SheetMusicAudioApple` target immediately before the existing `SheetMusicAudio` target:

```swift
        .target(
            name: "SheetMusicAudioApple",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicMIDI",
                "SheetMusicAudioCore",
            ],
        ),
```

And change the existing `SheetMusicAudio` target to depend on `SheetMusicAudioApple` instead of carrying its files itself. (At this point `Sources/SheetMusicAudio/` has zero `.swift` files — Step 2 moved them all out — so SwiftPM would fail to compile it. T5 creates the umbrella file; for now, keep the target dependency but leave umbrella content for T5.)

Actually defer the `SheetMusicAudio` target edit to T5 — we will combine it with the umbrella creation. For T4, just add the `SheetMusicAudioApple` target and product; the build will be momentarily broken between T4 and T5 because `Sources/SheetMusicAudio/` is empty. That's fine — T4 doesn't commit a building state on its own; it commits with T5 right after.

**Skip Step 5 commit at the end of T4 — merge T4 and T5 into a single commit at the end of T5.**

- [ ] **Step 5: Sanity check that the source directories look right**

Run:
```bash
ls Sources/SheetMusicAudio
ls Sources/SheetMusicAudioApple
ls Sources/SheetMusicAudioApple/Export
ls Sources/SheetMusicAudioCore
```
Expected:
- `Sources/SheetMusicAudio/` contains only `README.md` (will get rewritten in T10).
- `Sources/SheetMusicAudioApple/` contains the 5 root files.
- `Sources/SheetMusicAudioApple/Export/` contains the 2 export files.
- `Sources/SheetMusicAudioCore/` is unchanged from T3.

No commit yet — proceed to T5.

---

## Task 5: Create umbrella `SheetMusicAudio.swift` and finalize manifest

**Files:**
- Create: `Sources/SheetMusicAudio/SheetMusicAudio.swift`
- Modify: `Package.swift` (`SheetMusicAudio` target dependencies)

- [ ] **Step 1: Create the umbrella source file**

```swift
// Sources/SheetMusicAudio/SheetMusicAudio.swift
//
// Umbrella module for swift-sheet-music's audio sub-libraries.
//
// Apple hosts: re-exports both the Foundation-only core types and the
// AVFoundation-backed implementation (PlaybackEngine, audio file
// writers, etc.). Android hosts: only the Core types are visible;
// `PlaybackEngine` and friends are absent at the module level, which
// makes "no Android audio backend yet" a compile-time fact.
//
// Phase 4 will revisit this when an Android backend is added — at
// that point we may introduce an explicit `AudioBackend` protocol
// or keep the target boundary as the only abstraction.

@_exported import SheetMusicAudioCore

#if canImport(AVFoundation)
@_exported import SheetMusicAudioApple
#endif
```

- [ ] **Step 2: Update `Package.swift` — make `SheetMusicAudio` an umbrella**

In the `if !isAndroid { targets += [ ... ] }` block, change the existing `SheetMusicAudio` target to depend only on the two split halves:

```swift
        .target(
            name: "SheetMusicAudio",
            dependencies: [
                "SheetMusicAudioCore",
                "SheetMusicAudioApple",
            ],
        ),
```

The non-Android-side `SheetMusicAudio` is now a pure re-export of `Core + Apple`. (On Android, the `SheetMusicAudio` target / product is excluded entirely because it lives inside the `if !isAndroid` branch — Android consumers must `import SheetMusicAudioCore` directly. This matches the spec.)

- [ ] **Step 3: macOS build**

Run:
```bash
swift build 2>&1 | tail -10
```
Expected: build succeeds. `Sources/SheetMusicAudio/SheetMusicAudio.swift` compiles, transitively re-exporting both sub-modules. No other source change is needed because the Example / RenderPreviews / Tests all `import SheetMusicAudio` and `@_exported import` propagates type visibility.

- [ ] **Step 4: macOS test (sanity check — full suite comes in T7)**

Run:
```bash
swift test --filter PlaybackTimelineTests 2>&1 | tail -5
swift test --filter AudioFileFormatTests 2>&1 | tail -5
swift test --filter MixerChannelTests 2>&1 | tail -5
```
Expected: all three suites pass.

- [ ] **Step 5: Verify Android still cross-compiles**

Run:
```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28 2>&1 | tail -10
```
Expected: build succeeds. `SheetMusicAudio` / `SheetMusicAudioApple` are absent from the Android graph; only `SheetMusicAudioCore` participates.

- [ ] **Step 6: Commit T4 + T5 together**

```bash
git add Sources/SheetMusicAudio/SheetMusicAudio.swift \
        Sources/SheetMusicAudioApple \
        Package.swift
git commit -m "audio: split SheetMusicAudio into umbrella + Apple-only target

Phase 3 step 2/3. Moves the 7 AVFoundation-dependent files (PlaybackEngine
and its extensions, MetronomeController, MIDISynthBuilder, AudioExportWriter,
AudioFileExporter) into SheetMusicAudioApple, then converts SheetMusicAudio
into a thin umbrella that re-exports both halves via @_exported import.

Apple consumers see no API change — 'import SheetMusicAudio' still resolves
PlaybackEngine. The SheetMusicAudio + SheetMusicAudioApple targets and
products are gated behind '!isAndroid'; Android sees only SheetMusicAudioCore
in the package graph."
```

---

## Task 6: Update Apple-gated tests to `@testable import SheetMusicAudioApple`

Tests that touch `PlaybackEngine` internals (`postProcessForMIDISynth(midi:)`, `setStateForExport(_:)`, `exportTimeline()`, etc.) need a `@testable import SheetMusicAudioApple` because `@_exported import` does **not** propagate `@testable` access (CLAUDE.md "Recurring pitfalls"). Tests that only touch Foundation-only types can keep `@testable import SheetMusicAudio` — that pulls `SheetMusicAudioCore`'s testable surface through the umbrella, which works because the umbrella's `@_exported import SheetMusicAudioCore` is transitive for testability of types in the same module *only when* the importing module has `@testable` access to the umbrella. To stay safe and consistent, switch all Audio-touching tests to import the specific underlying target.

**Files:**
- Modify: each test file identified in T1 Step 5 plus any others that fail at build

- [ ] **Step 1: Run the full test build to discover broken imports**

Run:
```bash
swift build --build-tests 2>&1 | tail -30
```
Expected: a list of compile errors in test files that use internal symbols of `SheetMusicAudioApple` (typical message: `cannot find 'postProcessForMIDISynth' in scope`).

If the build is already green, skip Steps 2-5 and go to Step 6.

- [ ] **Step 2: For each failing test file, add `@testable import SheetMusicAudioApple`**

Pattern — change the `#if !os(Android)` block from:

```swift
#if !os(Android)
    @testable import SheetMusicAudio
    import SheetMusicCore
    import Testing
```

to:

```swift
#if !os(Android)
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import Testing
```

The third line (`@testable import SheetMusicAudioCore`) is included for files that touch internal types of `SheetMusicAudioCore` as well (e.g. internal initializers on `MetronomeBeat`). For files that only need `SheetMusicAudioApple`, omit the Core line.

Use grep to confirm which files need which line:

```bash
grep -lE 'postProcessForMIDISynth|setStateForExport|exportTimeline\(|MIDISynthBuilder\(|MetronomeController\(' \
  Tests/SheetMusicTests/*.swift
```
Add `@testable import SheetMusicAudioApple` to each match.

```bash
grep -lE '@testable import SheetMusicAudio$' Tests/SheetMusicTests/*.swift
```
The full list of files using `@testable import SheetMusicAudio` — review whether any uses internal-only types that the umbrella's `@_exported` doesn't propagate (rare; only if you see compile errors).

- [ ] **Step 3: Re-run the test build**

Run:
```bash
swift build --build-tests 2>&1 | tail -10
```
Expected: build succeeds.

- [ ] **Step 4: Run the full test suite**

Run:
```bash
swift test 2>&1 | tail -5
```
Expected: same green count as the Task 1 baseline.

- [ ] **Step 5: Verify Android test build is unaffected**

Run:
```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28 --build-tests 2>&1 | tail -10
```
Expected: builds successfully. All Audio-gated tests are inside `#if !os(Android)`, so the new `@testable import SheetMusicAudioApple` line is hidden from the Android build.

- [ ] **Step 6: Commit**

```bash
git add Tests/SheetMusicTests
git commit -m "test(audio): use @testable import SheetMusicAudioApple for engine internals

The umbrella SheetMusicAudio's @_exported import does not propagate
@testable access; tests that reach into PlaybackEngine internals
(postProcessForMIDISynth, setStateForExport, exportTimeline) need an
explicit @testable import of the underlying Apple-only module."
```

If Step 1 found no failures, skip this whole commit — record "no testable-import changes needed" in the plan progress notes and proceed to T7.

---

## Task 7: macOS full verification (swift build + swift test + xcodebuild iOS)

**Files:** read-only

- [ ] **Step 1: Full SwiftPM test run**

Run:
```bash
swift test 2>&1 | tail -5
```
Expected: matches the Task 1 baseline count exactly (e.g. `Test run with 1119 tests passed`).

- [ ] **Step 2: MidiExportTests semantic-equivalence subset**

Run:
```bash
swift test --filter MidiExportTests 2>&1 | tail -5
```
Expected: 12 cases pass.

- [ ] **Step 3: Regenerate Example xcodeproj**

Run:
```bash
cd Example
xcodegen generate
cd ..
```
Expected: project regenerates without warnings. The `project.yml` references the `SheetMusicAudio` product, which still exists post-split (now as the umbrella).

- [ ] **Step 4: iOS Simulator build**

Run:
```bash
xcodebuild \
  -project Example/SheetMusicExample.xcodeproj \
  -scheme SheetMusicExample \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build 2>&1 | tail -20
```
Expected: `BUILD SUCCEEDED`. `import SheetMusicAudio` in `Example/SheetMusicExample/**` resolves `PlaybackEngine`, `MixerChannel`, `AudioFileExporter`, etc., via the umbrella.

- [ ] **Step 5: macOS Example build**

Run:
```bash
xcodebuild \
  -project Example/SheetMusicExample.xcodeproj \
  -scheme SheetMusicExampleMac \
  -destination 'platform=macOS' \
  build 2>&1 | tail -20
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: No commit**

This task is verification-only. If any step fails, fix the cause (most likely an Example file needs an additional `import SheetMusicAudioApple` for an internal symbol it shouldn't have been touching, or a `project.yml` dependency needs adjustment) and commit that fix as part of T8 or T10.

---

## Task 8: Android cross-compile full verification

**Files:** read-only

- [ ] **Step 1: Confirm toolchain pin**

Run:
```bash
echo "$TOOLCHAINS"
swift --version | head -1
```
Expected: `TOOLCHAINS=org.swift.632202605101a`; banner contains `swift-6.3.2-RELEASE`.

If `TOOLCHAINS` is empty, export it for the subsequent commands:
```bash
export TOOLCHAINS=org.swift.632202605101a
```

- [ ] **Step 2: Library-only build**

Run:
```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
    --swift-sdk aarch64-unknown-linux-android28 2>&1 | tail -10
```
Expected: build succeeds.

- [ ] **Step 3: Build with tests**

Run:
```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
    --swift-sdk aarch64-unknown-linux-android28 \
    --build-tests 2>&1 | tail -10
```
Expected: build succeeds; no module not found errors for `SheetMusicAudioApple` (the `#if !os(Android)` gates hide every reference).

- [ ] **Step 4: Verify package graph excludes Apple-only audio target**

Run:
```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe --type json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("\n".join(sorted(t["name"] for t in d["targets"])))'
```
Expected (alphabetical):
```
SheetMusic
SheetMusicAudioCore
SheetMusicCore
SheetMusicLayout
SheetMusicMIDI
SheetMusicMSCX
SheetMusicMusicXML
SheetMusicTests
SheetMusicXMLTools
SheetMusicZip
```
No `SheetMusicAudio`, `SheetMusicAudioApple`, or any other Apple-only target. Compare against the same command on the Apple side:

```bash
swift package describe --type json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("\n".join(sorted(t["name"] for t in d["targets"])))'
```
Expected (alphabetical):
```
RenderPreviews
SheetMusic
SheetMusicAudio
SheetMusicAudioApple
SheetMusicAudioCore
SheetMusicCore
SheetMusicLayout
SheetMusicLayoutApple
SheetMusicMIDI
SheetMusicMSCX
SheetMusicMusicXML
SheetMusicPDF
SheetMusicTests
SheetMusicUI
SheetMusicXMLTools
SheetMusicZip
```

- [ ] **Step 5: Android device smoke test**

Run:
```bash
Scripts/android-test.sh aarch64 2>&1 | tail -20
```
Expected: tests build, deploy to a connected device/emulator, and run. Foundation-only tests (incl. anything new in `SheetMusicAudioCore` — but Phase 3 adds no new tests, only moves them) pass. Audio-gated tests are skipped because of `#if !os(Android)`.

If no device is connected, document this gap and proceed — Step 2-4 cover the static side.

- [ ] **Step 6: No commit**

Verification-only. If Step 2 fails (most likely cause: a stray `#if canImport(AVFoundation)` missing or `Sources/SheetMusic/` umbrella indirectly importing something Apple-only), fix and commit alongside T10.

---

## Task 9: SwiftLint

**Files:** any source file with lint regression

- [ ] **Step 1: Run SwiftLint over `Sources` and `Tests`**

Run:
```bash
swiftlint --quiet Sources Tests 2>&1 | tail -20
```
Expected: `0 violations`.

- [ ] **Step 2: If `file_length` fires on `PlaybackEngine.swift`**

`PlaybackEngine.swift` already has `// swiftlint:disable file_length` on line 1 — that should carry over with the `git mv` to `Sources/SheetMusicAudioApple/PlaybackEngine.swift`. If `swiftlint` reports `file_length` regardless, verify the marker is still present:

```bash
head -1 Sources/SheetMusicAudioApple/PlaybackEngine.swift
```
Expected: `// swiftlint:disable file_length`. If missing, re-add it.

- [ ] **Step 3: Commit any fixes**

If Step 1 reported violations and Step 2 added the disable marker back:

```bash
git add Sources/SheetMusicAudioApple
git commit -m "lint: restore swiftlint:disable file_length on moved PlaybackEngine"
```

If Step 1 was already clean, skip Step 3.

---

## Task 10: Update CLAUDE.md, README.md, and roadmap memory

**Files:**
- Modify: `CLAUDE.md`
- Modify: `Sources/SheetMusicAudio/README.md`
- Modify: `/Users/kiichi/.claude/projects/-Users-kiichi-Developer-Personal-swift-packages-swift-sheet-music/memory/project_android_port_roadmap.md`
- Modify: `/Users/kiichi/.claude/projects/-Users-kiichi-Developer-Personal-swift-packages-swift-sheet-music/memory/MEMORY.md` (entry text only)

- [ ] **Step 1: Update `CLAUDE.md` Library layout block**

Find the block (under `## Library layout`) that currently reads:

```
SheetMusicAudio       (AVFoundation playback + audio file export;
                       → Core, MIDI)
```

Replace with:

```
SheetMusicAudio            (umbrella; → Core, Apple)
  ├─→ SheetMusicAudioCore     (Foundation-only types: PlaybackTimeline,
  │                            MetronomeBeat, GMInstrument, MixerChannel,
  │                            LoopRange, PlaybackState, AudioFileFormat …;
  │                            → Core, MIDI)
  └─→ SheetMusicAudioApple    (AVFoundation playback + audio file export;
                               Apple-only; → Core, MIDI, AudioCore)
```

- [ ] **Step 2: Update `CLAUDE.md` Android build block**

Find the sentence:

```
UI / PDF / Audio remain Apple-only pending Phase 3 audio DI.
```

Replace with:

```
SheetMusicAudioCore is also Android-compatible (Foundation-only audio
value types like PlaybackTimeline / MetronomeBeat / AudioFileFormat).
UI / PDF remain Apple-only pending Phase 4 (Android backend).
```

Also find:

```
+ (Phase 2, via the
  `FontMetricsProvider` DI seam — Apple hosts auto-install
  `SheetMusicLayoutApple`'s CoreText backend through UI / PDF; Android
  falls back to a `StubFontMetricsProvider` with rectangle
  approximations). UI / PDF / Audio remain Apple-only pending Phase 3
  audio DI.
```

And change the trailing sentence the same way (single replacement covers this if both sentences are identical; otherwise edit both).

- [ ] **Step 3: Rewrite `Sources/SheetMusicAudio/README.md`**

Replace the contents with:

```markdown
# SheetMusicAudio

Umbrella module for swift-sheet-music's audio sub-libraries.

- On Apple platforms, `import SheetMusicAudio` re-exports both
  `SheetMusicAudioCore` (Foundation-only value types) and
  `SheetMusicAudioApple` (AVFoundation-backed `PlaybackEngine`,
  audio file export, metronome, MIDI synth builder).
- On Android, only `SheetMusicAudioCore` participates in the build
  graph; `PlaybackEngine` and friends are absent. Phase 4 will
  introduce an actual Android backend (AAudio / Oboe bridge or a
  pure-Swift PCM renderer); until then "Android audio playback"
  is a compile-time absence by design.

## Sub-targets

| Target | Platform | Contents |
|---|---|---|
| `SheetMusicAudioCore` | All (Foundation-only) | Playback timeline, metronome beats, GM instrument table, mixer channel, loop range, playback state, audio file format / range / error enums. |
| `SheetMusicAudioApple` | Apple-only (`canImport(AVFoundation)`) | `PlaybackEngine` + extensions, `MetronomeController`, `MIDISynthBuilder`, `AudioExportWriter`, `AudioFileExporter`. |
| `SheetMusicAudio` | Apple-only (umbrella) | `@_exported import` of both above. |

Apple consumers should keep writing `import SheetMusicAudio`. Android
consumers must `import SheetMusicAudioCore` directly.

## Audio file export

```swift
let engine = PlaybackEngine(soundfontResolver: myResolver)
try engine.prepare(score: score)

let url = URL(fileURLWithPath: "/tmp/song.wav")
try await engine.exportAudioFile(
    to: url,
    score: score,
    range: .fullScore,
    format: .wav(.init())
)
```

(See `Sources/SheetMusicAudioApple/Export/` for the writer back-ends and
`Sources/SheetMusicAudioCore/Export/` for the format / error / range
value types.)
```

- [ ] **Step 4: Update roadmap memory**

Open `/Users/kiichi/.claude/projects/-Users-kiichi-Developer-Personal-swift-packages-swift-sheet-music/memory/project_android_port_roadmap.md` and change the status line that previously read something like "Phase 2 complete, Phase 3 pending" to reflect Phase 3 complete and Phase 4 (Kotlin Compose example) as the only remaining phase. Keep wording style consistent with the existing entry — the `MEMORY.md` index hook should also be updated to summarize "Phase 3 完了" alongside Phase 2.

(Memory files are outside the worktree but governed by the user — edit in place; they are not part of the git commit.)

- [ ] **Step 5: macOS + Android re-build sanity**

After doc edits:

```bash
swift build 2>&1 | tail -5
SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28 2>&1 | tail -5
```
Expected: both succeed.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md Sources/SheetMusicAudio/README.md
git commit -m "docs(audio): document SheetMusicAudio split into Core + Apple

Reflects the Phase 3 target boundary in the project's two main docs:
CLAUDE.md's 'Library layout' and 'Android build' sections, plus the
SheetMusicAudio README. Memory roadmap entry is updated separately
(lives outside the repo)."
```

---

## Task 11: Manual Mac UI verification + finishing branch

**Files:** none modified

- [ ] **Step 1: Build SheetMusicExampleMac**

Run:
```bash
xcodebuild \
  -project Example/SheetMusicExample.xcodeproj \
  -scheme SheetMusicExampleMac \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/swift-sheet-music-audio-di-dd \
  build 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`. Record the built `.app` path under `/tmp/swift-sheet-music-audio-di-dd/Build/Products/Debug/SheetMusicExampleMac.app`.

- [ ] **Step 2: Hand the .app to the user for manual verification**

Surface the path to the user with:

> "Built SheetMusicExampleMac.app — please exercise: load a score, play, pause, seek, loop, change rate, toggle mute/solo on the mixer, toggle metronome on/off, and export a WAV. Reply with the result."

Do **not** drive UI gestures programmatically (CLAUDE.md "Visual verification — Mac app").

- [ ] **Step 3: After the user confirms**

Once the user reports all checks green, run a final clean status check:

```bash
git status --short
git log --oneline ba318fd..HEAD
```
Expected: clean tree; commits from T2 / T3 / T5 / (optionally T6) / T9 / T10 in order.

- [ ] **Step 4: Hand off to `superpowers:finishing-a-development-branch`**

Invoke the `superpowers:finishing-a-development-branch` skill to choose between merge / PR / cleanup. Do not merge or push without explicit user authorization.

---

## Self-review checklist

- **Spec coverage**: every Architecture / Package.swift / Data flow / Errors / Testing item in the spec maps to a task above. The "umbrella circular dependency" risk in the spec is the topology resolved by T3 + T5 (Core has no Apple dep; Apple depends on Core; umbrella depends on both). The `@_exported import` risk is verified by T7 Step 4 / Step 5 (iOS + Mac xcodebuild). Test-gating range is enumerated in T6.
- **No placeholders**: every code step shows the exact code; every command step shows the exact command and the expected output.
- **Type consistency**: target names `SheetMusicAudioCore` / `SheetMusicAudioApple` / `SheetMusicAudio` are used identically across all tasks. File paths `Sources/SheetMusicAudioCore/`, `Sources/SheetMusicAudioApple/`, `Sources/SheetMusicAudio/` likewise. The branch name throughout is `worktree-audio-backend-di` (the worktree-tool default) — explicitly different from the spec's `feature/audio-backend-di` and explained at the top.

---

## Execution handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-19-audio-backend-di.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task with two-stage review between tasks. Good fit here because tasks T2 / T3 / T4+T5 / T6 / T9 / T10 each produce a single commit and the verification tasks (T7 / T8 / T11) are read-only.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`. Faster, but no inter-task review.

**Which approach?**
