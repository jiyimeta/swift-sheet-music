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
SheetMusicAudio       (AVFoundation playback + audio file export;
                       → Core, MIDI)
SheetMusicPDF         (PDF export; → Core, Layout, LayoutApple, UI)
```

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
cd Example && xcodegen generate                 # regenerate after editing project.yml
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build
```

The example app's `.xcodeproj` is **gitignored**; regenerate from
`Example/project.yml` with `xcodegen` whenever you change project
settings or sources.

## Android build (Phase 1–2)

`swift-sheet-music` cross-compiles to Android via the Swift 6.3 official
Android SDK. Foundation-only targets supported: Core / MIDI / MSCX /
MusicXML / XMLTools (Phase 1) + Layout (Phase 2, via the
`FontMetricsProvider` DI seam — Apple hosts auto-install
`SheetMusicLayoutApple`'s CoreText backend through UI / PDF; Android
falls back to a `StubFontMetricsProvider` with rectangle
approximations). UI / PDF / Audio remain Apple-only pending Phase 3
audio DI.

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
      https://download.swift.org/swift-6.3.2-release/swift-6.3.2-RELEASE_android-0.1.artifactbundle.tar.gz \
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

### Format support on Android

`.mscz` and `.mxl` are fully supported on Android via the in-house
`SheetMusicZip` target (raw DEFLATE through system `libz`). No
additional setup is required beyond the Phase 1 toolchain.

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
  silently skipped (see `MSCXDecoder+Voice.swift`). Required elements
  that genuinely can't be defaulted throw `SheetMusicError.malformedScore`.
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
- **Xcode project drift**: `Example/SheetMusicExample.xcodeproj` is
  gitignored. After changing example sources or `project.yml`,
  regenerate with `cd Example && xcodegen`.
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
