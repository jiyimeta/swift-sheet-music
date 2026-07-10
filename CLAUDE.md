# CLAUDE.md

Project-specific guidance for Claude when working in this repository.

## What this is

`swift-sheet-music` is a Swift Package Manager library suite for working
with engraved music notation. It parses MuseScore (`.mscx`/`.mscz`) and
MusicXML files into a typed Swift score model, renders notation via SwiftUI,
exports to Standard MIDI Files, and supports AVFoundation-backed audio
playback and audio file export.

The package is **unofficial**: not affiliated with MuseScore Limited /
Muse Group, nor with Apple's `MusicKit` framework.

## Library layout

Public library products under this single package:

```
SheetMusic            (umbrella + small façade)
  ├─→ SheetMusicCore     (Score data model, SheetMusicError; no I/O)
  ├─→ SheetMusicMSCX     (mscx / mscz parsing + writing; → Core, XMLTools, ZIP)
  ├─→ SheetMusicMusicXML (MusicXML / MXL import; → Core, XMLTools, ZIP)
  └─→ SheetMusicMIDI     (in-memory MIDI model, render, SMF I/O; → Core)

SheetMusicLayout      (pure-geometry layout, Foundation-only,
                       Android-compatible; → Core)
SheetMusicLayoutApple (CoreText font metrics provider for Layout;
                       Apple-only; → Core, Layout)
SheetMusicUI          (SwiftUI views; → Core, Layout, LayoutApple)
SheetMusicAudio            (umbrella; → Core, Apple)
  ├─→ SheetMusicAudioCore     (Foundation-only types: PlaybackTimeline,
  │                            MetronomeBeat, GMInstrument, MixerChannel,
  │                            LoopRange, PlaybackState, AudioFileFormat …;
  │                            → Core, MIDI)
  └─→ SheetMusicAudioApple    (AVFoundation playback + audio file export;
                               Apple-only; → Core, MIDI, AudioCore)
SheetMusicPDF         (PDF export; → Core, Layout, LayoutApple, UI)
```

(Android audio lives at `Android/SheetMusicAudioAndroid/` — a Kotlin
Gradle module producing an .aar artifact, not a SwiftPM target.
See its README for usage.)

Internal targets (not products): `SheetMusicXMLTools`.

Dev executable: `RenderPreviews`.

`SheetMusic` re-exports Core + MSCX + MusicXML + MIDI with
`@_exported import` and adds the convenience façade. `Layout`,
`UI`, `Audio`, and `PDF` are not re-exported (consumers opt in
explicitly).

## File layout (source)

```
Sources/SheetMusic/SheetMusic.swift                        umbrella + façade
Sources/SheetMusicCore/SheetMusicError.swift               shared error type
Sources/SheetMusicCore/Score/<Type>.swift                  one file per Score type
Sources/SheetMusicMSCX/XML/{XMLNode,XMLTreeParser}.swift   Foundation XMLParser wrapper
Sources/SheetMusicMSCX/MSCXParser.swift                    public façade
Sources/SheetMusicMSCX/Decoders/MSCXDecoder+<Type>.swift   one decoder extension per type
Sources/SheetMusicMIDI/Model/<Type>.swift                  MidiEvent, MetaEvent, MidiFile, …
Sources/SheetMusicMIDI/Render/MidiRenderer{,+ext}.swift    score → MidiFile (split for length)
Sources/SheetMusicMIDI/IO/{BinaryEncoder,VariableLengthQuantity,MidiWriter}.swift
Sources/SheetMusicAudio/Export/
  AudioFileFormat.swift, AudioExportRange.swift,
  AudioExportError.swift, AudioExportWriter.swift,
  AudioFileExporter.swift
Sources/SheetMusicAudio/PlaybackEngine+Export.swift
```

## Build / test / run

```bash
# Build & test the package
swift build
swift test                                      # should be 100% green
swift test --filter MidiExportTests             # the 12 MuseScore-equivalence cases

# Lint (optional, requires brew install swiftlint)
swiftlint --quiet Sources Tests                 # should be 0 warnings/errors

# Example app (iOS Simulator)
cd Examples/Apple && xcodegen generate          # regenerate after editing project.yml
xcodebuild -project Examples/Apple/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Pre-merge verification (CI + local preflight)

GitHub Actions runs on public runners (free for public repos):

- `ci.yml` — Apple `swift build` + `swift test`, on every push and pull
  request to `main`. Needs no secrets, so it also covers fork PRs. This is
  the primary gate.
- `android-audio.yml` — Android cross-compile → Kotlin unit tests →
  `assembleRelease`, on push to `main` and `workflow_dispatch`. Not run on
  `pull_request` because it needs the `WIRELET_PAT` GitHub Packages token,
  which forks can't access. ~40-75 min on a `macos-14` runner.
- `android-publish.yml` — fires on `v*` tags (release publish, infrequent).

`Scripts/preflight.sh` remains the fast **local** gate — run it before
opening a PR / merging, especially for Android changes (CI only verifies
those post-merge to `main`):

```bash
Scripts/preflight.sh            # full suite: Apple swift test + Android
Scripts/preflight.sh --apple    # Apple/SwiftPM only (fast iteration)
Scripts/preflight.sh --android  # Android cross-compile + Kotlin tests + AAR
```

The Android stage needs the same toolchain/SDK/NDK + `WIRELET_PAT` setup
documented under "Android build" below; on a host without that, use
`--apple`.

The example app's `.xcodeproj` is **gitignored**; regenerate from
`Examples/Apple/project.yml` with `xcodegen` whenever you change project
settings or sources.

### Worktree setup — symlink the gitignored `Sounds/`

`Examples/Apple/SheetMusicExample/Sounds/` is **gitignored** — its sole
content (`MuseScore_General.sf2`, ~215 MB) lives in the main worktree and
is distributed via GitHub Releases, not git. Secondary worktrees (under
`.claude/worktrees/…`) start without the directory, so the Apple example
app can't find the bundled SoundFont and plays silence.

After creating a worktree, run once from inside it:

```bash
Scripts/link-apple-sounds.sh
```

The script symlinks the worktree's `Sounds/` to the main worktree's copy
(idempotent; no-op from the main worktree itself). When working in a
worktree, Claude should run this once at the start of the session if the
Apple example app is in scope. Avoid duplicating the 215 MB sf2 across
worktrees.

## Android build (Phase 1–3)

`swift-sheet-music` cross-compiles to Android via the Swift 6.3 official
Android SDK. Foundation-only targets supported: Core / MIDI / MSCX /
MusicXML / XMLTools (Phase 1) + Layout (Phase 2, via the
`FontMetricsProvider` DI seam — Apple hosts auto-install
`SheetMusicLayoutApple`'s CoreText backend through UI / PDF; Android
falls back to a `StubFontMetricsProvider` with rectangle
approximations). SheetMusicAudioCore is also Android-compatible
(Foundation-only audio value types like PlaybackTimeline /
MetronomeBeat / AudioFileFormat). Audio playback on Android is
delivered as a Kotlin Gradle module at `Android/SheetMusicAudioAndroid/`
(FluidSynth via VolcanoMobile's `.aar` + `AudioTrack` for v0).
UI / PDF remain Apple-only.

### Prerequisites

- **Open-source swift.org Swift 6.3.2-RELEASE toolchain on the host**
  (not Apple's Xcode-shipped Swift). Install the `.pkg` from
  <https://www.swift.org/install/macos/> (lands at
  `/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain`,
  bundle id `org.swift.632202605101a`). Export `TOOLCHAINS=org.swift.632202605101a`
  before any Android `swift build` (or rely on `Scripts/android-test.sh`
  which exports it for you). The Android SDK's pre-built Foundation
  swiftmodule is tagged `Swift version 6.3.2 (swift-6.3.2-RELEASE)` and
  Apple's Xcode-shipped `swiftlang-6.3.2.*` fork rejects it with
  214 "compiled module was created by an older version of the compiler"
  errors.

  ```bash
  export TOOLCHAINS=org.swift.632202605101a
  swift --version  # banner should contain "swift-6.3.2-RELEASE"
  ```

- Swift Android SDK installed. `swift sdk list` should report:

  ```
  swift-6.3.2-RELEASE_android
  ```

  This bundle exposes triples `{aarch64,x86_64,armv7}-unknown-linux-android{28..36}`.
  It does **not** include `android24`. The lowest API level supported
  is `android28`. Install via:

  ```bash
  swift sdk install \
      https://download.swift.org/swift-6.3.2-release/android-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_android.artifactbundle.tar.gz \
      --checksum <SHA256-from-swift.org-release-page>
  ```

  Re-derive the exact URL and checksum from
  <https://www.swift.org/install/> → Swift 6.3 → Android if either
  changes.

- `adb` on `$PATH` and an Android device or emulator (API ≥ 28)

### One-time NDK sysroot setup

The Swift Android SDK ships a setup script that stages NDK sysroot
symlinks. Run it once after installing the SDK:

```bash
ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/<version> \
    ~/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh
```

If the `ndk-sysroot` symlink under the artifact bundle is missing, the
cross-compile fails with `'semaphore.h' file not found` /
`could not build C module 'SwiftOverlayShims'`.

### Distribution

The Android libraries are published to GitHub Packages on `v*` tag
push via `.github/workflows/android-publish.yml`. Two artifacts:

- `io.github.jiyimeta:sheet-music-android:<v>` — JNI bridge + bundled
  `libSheetMusicJNI.so` (the new home for what used to be the
  example-app's `com.example.sheetmusic.jni` package).
- `io.github.jiyimeta:sheet-music-audio-android:<v>` — FluidSynth +
  Oboe audio playback. Has `api` dep on `sheet-music-android`.

Consumers need a GitHub PAT with `read:packages`. See
`Android/SheetMusicAndroid/README.md` for the consumer-side
`settings.gradle.kts` recipe.

To cut a release locally without CI:

    Scripts/android-build-libs.sh
    GITHUB_ACTOR=<user> GITHUB_TOKEN=<pat> ./Android/gradlew \
        -Pversion=0.1.0 \
        -p Android \
        :SheetMusicAndroid:publishReleasePublicationToGithubPackagesRepository \
        :SheetMusicAudioAndroid:publishReleasePublicationToGithubPackagesRepository

### Format support on Android

`.mscz` and `.mxl` are fully supported on Android via the in-house
`SheetMusicZip` target (raw DEFLATE through system `libz`). No
additional setup is required beyond the Phase 1 toolchain.

### Android playback engine

`AndroidPlaybackEngine` (Kotlin, `Android/SheetMusicAudioAndroid/`)
mirrors `SheetMusicAudioApple.PlaybackEngine`: looping by measure range
or through end-of-score (+ clear), rate, per-staff program change, and
live master tuning via FluidSynth RPN (used for A4 calibration). Loop
wrap is host-driven inside the engine's poll loop (FluidSynth's
`fluid_player_set_loop` loops the entire SMF only). Rate uses
`fluid_player_set_tempo` in `FLUID_PLAYER_TEMPO_INTERNAL` mode; program
change reuses the existing sfid via `programSelect`.

GMInstrument is single-sourced from Swift `SheetMusicAudioCore`;
Kotlin loads the 128-patch table via `nativeGMInstrumentList()` JNI on
first access (see `Sources/SheetMusicAndroidJNI/Audio/GMInstrumentCodec.swift`).
The multi-system loop highlight is plumbed through
`LayoutDocument.loopHighlightRects(fromMeasureIndex:toMeasureExclusive:)`
+ `nativeLoopHighlightRects` JNI + `LoopHighlightOverlay` composable.
`PlaybackTimeline.frame(forCursor:)` falls back to a tick-based
lookup for `.beat` cursors whose dedicated frame was dropped by the
dedup against an item at the same tick (otherwise a loop boundary on a
downbeat would silently no-op).

### Android example app

An end-to-end Kotlin Compose demo lives in `Examples/Android/`. It
parses an `.mscz` from the app's `assets/`, computes layout via the
JNI bridge (`Sources/SheetMusicAndroidJNI`), renders pages to a
Compose `Canvas`, and plays back through `sheet-music-audio-android`
(FluidSynth + Oboe) with mixer and audio-file export — see
`Examples/Android/app/src/main/java/com/example/sheetmusic/audio/`
(`EnginePlayer`, `MixerPanel`, `PlaybackService`, `export/`). Audible
playback requires a General MIDI SoundFont staged into `assets/`
(quickstart below); without it the Play button stays disabled.

Quickstart (from repo root):

    # 1. Build native libs into Android/SheetMusicAndroid/src/main/jniLibs/
    Scripts/android-build-libs.sh

    # 2. Copy a MuseScore file you own into the app's assets
    cp /path/to/your.mscz ~/Desktop/test.mscz

    # 3. (Optional) Copy a General MIDI SoundFont to enable audio playback.
    #    Download e.g. GeneralUserGS (https://schristiancollins.com/generaluser.php)
    #    and save as ~/Desktop/gm.sf2. The Play button stays disabled without it.
    cp /path/to/GeneralUserGS.sf2 ~/Desktop/gm.sf2

    # 4. Stage assets into app/src/main/assets/ (copies both test.mscz + gm.sf2)
    Scripts/android-bundle-test-score.sh

    # 5. Open Examples/Android/ in Android Studio and Run

Supported ABIs: `arm64-v8a`, `x86_64`. Lowest API level: 28.
Glyph rendering uses `StubFontMetricsProvider` rectangle approximations
on Android — replacing with a SMuFL-aware Android provider is a future
phase.

### `--swift-sdk` argument form

Both forms work; we use the triple form for explicit API-level / arch
selection:

- **Triple form (preferred):** `aarch64-unknown-linux-android28` or
  `x86_64-unknown-linux-android28`. Used by `Scripts/android-test.sh`.
- **Bundle form:** `swift-6.3.2-RELEASE_android`. SwiftPM picks the
  triple (observed default: `aarch64-unknown-linux-android29`). Handy
  for ad-hoc commands when you don't care which API level is picked.

### Building

```bash
# Library targets only — fast
SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
    --swift-sdk aarch64-unknown-linux-android28

# With tests
SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
    --swift-sdk aarch64-unknown-linux-android28 \
    --build-tests
```

### Running tests on a device

```bash
Scripts/android-test.sh aarch64 [device-serial]
```

The script defaults to API level 28 (lowest available in the
SDK bundle). Pass a custom triple via env if you need a different
API level.

### Adding new tests

Tests that import any Apple framework (`SwiftUI`, `AVFoundation`,
`CoreText`, `CoreGraphics`, `AppKit`, `UIKit`, `PDFKit`) or that
`@testable import` an Apple-only sub-library (`SheetMusicLayout`,
`SheetMusicUI`, `SheetMusicAudio`, `SheetMusicPDF`) must be wrapped in
`#if !os(Android)` ... `#endif`. Run `Scripts/gate-android-tests.sh`
after creating new test files to apply this guard automatically.

### Wirelet bootstrap (Android only)

Android Gradle builds invoke the `io.github.jiyimeta.wirelet` plugin
(from `maven.pkg.github.com/jiyimeta/swift-wirelet`), which forks
`swift run` against a local checkout pinned by `swiftPackagePath` in
each module's `wirelet { … }` block. We point it at SwiftPM's own
checkout under `.build/checkouts/swift-wirelet/` so a single
`Package.resolved` revision is the source of truth — no separate
symlink or manual clone needed. Run once after cloning the repo:

    swift package resolve

That populates `.build/checkouts/swift-wirelet/` at the pinned
revision. Any subsequent `swift build` keeps it in sync.

The Maven side (`io.github.jiyimeta:wirelet-runtime`) requires
`~/.gradle/gradle.properties` to set `gpr.user` + `gpr.key` (a classic
GitHub PAT with `read:packages` scope). GitHub Packages requires
authentication even for public packages, so the PAT is needed to
download the plugin / runtime. Env vars `GITHUB_ACTOR` / `GITHUB_TOKEN`
also work if preferred.

To iterate on local wirelet changes, use SwiftPM's built-in override:

    swift package edit Wirelet --path /path/to/your/swift-wirelet

SwiftPM swaps the checkout dir for the edit path, and the Gradle
plugin's `swiftPackagePath` follows along automatically. Run
`swift package unedit Wirelet` to revert.

## Conventions

- **Idiomatic Swift naming.** Don't transliterate C++ names. When the
  rename is non-obvious, leave the original as a doc comment, e.g.
  `/// C++: mu::engraving::MasterScore`.
- **Value types preferred.** All Score / MIDI types are `struct` or
  `enum`. Sendable. No back-pointers; cross-references live in
  rendering passes, not in the model.
- **One responsibility per file.** SwiftLint caps file length at 300.
  When `MidiRenderer.swift` outgrew this it was split into
  `MidiRenderer+Header.swift`, `…+Voice.swift`, `…+Repeats.swift`, etc.
- **Permissive parser.** Unknown XML elements inside a `<voice>` are
  silently skipped (see `MSCXDecoder+Voice.swift`). For known elements
  with unknown / missing values, MSCX decoders use a three-way policy:
  - **Structural** (pitch, voice structure, time signature, division):
    throw `SheetMusicError.malformedScore` — the score can't be loaded
    coherently.
  - **Embellishment** (tremolo subtype, articulation kind, ornament
    subtype, fermata / breath style, hairpin shape, glissando style):
    drop the element and emit a `ScoreDiagnostic` via `mscxDecoderWarn`.
    The score still loads; the decoration is silently absent. Surface
    via `MSCXParser.parseWithDiagnostics(...)` /
    `MSCZReader.parseWithDiagnostics(...)`.
  - **Cosmetic** (color, offset, font, stroke style): silent default
    to the model's neutral value.
- **Errors via `throws`.** Single error enum `SheetMusicError`; no
  `Result` types; no Optional return for "failed" cases.
- **`MIDIRenderer` algorithm choices mirror MuseScore.** When you
  reproduce a MuseScore algorithm, reference the source line in a doc
  comment, e.g. `/// Mirrors CompatMidiRender::renderArpeggio`.

## Tests

Swift Testing (`import Testing`) — not XCTest. Test target depends on
all library products and uses `@testable import` on each
sub-library (re-exports do NOT transitively grant testable access).

```swift
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
@testable import SheetMusicLayout
@testable import SheetMusicUI
@testable import SheetMusicAudio
@testable import SheetMusicPDF
import Testing
```

`MidiExportTests` runs the 12 enabled cases of MuseScore's own
`midiexport_tests.cpp` via semantic-equivalence comparison
(`Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift`):
parse mscx → render → SMF bytes → reparse → compare event lists,
tolerating MuseScore's `tempomapWithPauses` restoration noise.

## Test fixtures (important)

`Tests/SheetMusicTests/Resources/*.mscx` and `*-ref.mid` are **GPL-3.0
copies of MuseScore's own test fixtures**. They are confined to the
test target and not part of any published library product. See:

- `Tests/SheetMusicTests/Resources/LICENSE` — per-directory notice
- `NOTICE` — full provenance and trademark statement
- `LICENSE` — MIT, applies only to `Sources/`

Don't move these fixtures into `Sources/` and don't ship them in any
library product.

## MuseScore C++ source as reference

The upstream MuseScore C++ source (<https://github.com/musescore/MuseScore>,
GPL-3.0) is used as a behavioural specification when porting algorithms.
It is **not** vendored into this repository — clone it separately when
you need to cross-reference. The Swift implementation is rewritten
independently from the studied behaviour; do not copy code structures
verbatim, and do not import any GPL source into `Sources/`.

`docs/musescore-engraving-reference.md` collects findings that recur
across porting work — coordinate units (DPI / DPMM / spatium),
`<offset>` / `OffsetType` semantics, frame layout, title-block style
defaults, read-path tiers. Consult / extend it before re-spelunking
the same C++ files. Path references in that doc (and in
`docs/incremental-layout-future.md`) are relative to the upstream
MuseScore repository root.

## Things not to do

- Don't vendor the MuseScore C++ source into this repository (it's
  GPL — keep it as an external reference only).
- Don't introduce GPL code into `Sources/`. The published source is MIT.
- Don't bundle the GPL-3.0 test fixtures under
  `Tests/SheetMusicTests/Resources/` into any library or executable
  product. They must stay confined to the test target — that's what
  keeps the package distributable as MIT under GPL §5 mere-aggregation.
  Keep them out of `Sources/`, never list them as resources of a
  `.target` / `.executableTarget`, and don't ship a binary that
  embeds them.
- Don't rename to anything containing `MuseScore` in the package or
  product names — trademark concerns drove the move to `swift-sheet-music`.
- Don't add `SheetMusicKit` either — Apple's `MusicKit` is a related
  prefix and the bare `SheetMusic` reads cleaner.
- Don't introduce intermediate "category" libraries (e.g.
  `SheetMusicFormats` re-exporting MSCX+MIDI). Flat re-export from
  `SheetMusic` is the chosen pattern; revisit only if format libraries
  proliferate beyond ~5.
- Don't update `docs/superpowers/{plans,specs}/` to the new naming —
  those are point-in-time design records and should remain as-is.
- Don't commit `Examples/Android/app/src/main/assets/test.mscz` — the
  file is for local testing only and not redistributable. The bundle
  script (`Scripts/android-bundle-test-score.sh`) copies it from
  `~/Desktop` and the destination is gitignored.

## Recurring pitfalls

- **macOS `sed -i` syntax**: BSD sed (default on macOS) doesn't accept
  the GNU `c\` form for line replacement. Prefer `awk` for line-aware
  text rewrites.
- **`sed` over `find` output**: zsh splits unquoted command substitution
  differently from bash. Use `find … | while read -r f; do …` to avoid
  "file name too long" errors.
- **`@_exported import` doesn't transitively re-export `@testable`
  access.** Test targets must `@testable import` each sub-library
  individually.
- **Xcode project drift**: `Examples/Apple/SheetMusicExample.xcodeproj` is
  gitignored. After changing example sources or `project.yml`,
  regenerate with `cd Examples/Apple && xcodegen`.
- **Audio file writer back-ends differ by format**: `AVAudioFile`
  natively writes WAV (URL `.wav`), AIFF (`.aiff` int / `.aifc`
  float), and M4A (settings dict `kAudioFormatMPEG4AAC`). Only
  MP3 needs `AVAssetWriter` (and only on iOS 17 / tvOS 17 /
  watchOS 10 — `AVAssetWriter` rejects `.mp3` on macOS at runtime,
  even on 14+). Do not reach for `AVAssetWriter` for the others —
  it is more code for no benefit. See
  `SheetMusicAudio/Export/AudioExportWriter.swift`.
- **Android cross-compile and Package.swift**: the manifest reads
  `SWIFT_SHEET_MUSIC_ANDROID` at evaluation time. After editing
  `Package.swift`, re-run `swift package describe` both with and
  without the env var set to confirm both shapes still resolve.
