# swift-sheet-music

[![CI](https://github.com/jiyimeta/swift-sheet-music/actions/workflows/ci.yml/badge.svg)](https://github.com/jiyimeta/swift-sheet-music/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20Android-blue.svg)](#installation)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](#installation)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A Swift package for working with engraved music notation: parsing
MuseScore (`.mscx` / `.mscz`) and MusicXML (`.musicxml` / `.mxl`) score
files, modelling them as Swift value types, exporting them back to
MuseScore format or to Standard MIDI Files, rendering to SwiftUI /
PDF, and playing them back via AVFoundation. Built from scratch in
Swift, with no direct runtime dependency on the MuseScore application.

A subset of the package (parsing, model, MIDI, layout, audio types)
cross-compiles to Android via the Swift 6.3 official Android SDK and
is consumable from Kotlin through a Gradle module that ships as an
`.aar`. See [Android](#android) below.

> **Status:** unofficial. Not affiliated with MuseScore Limited / Muse Group,
> nor with Apple's `MusicKit` framework (which is for Apple Music integration).

## Libraries

The package is split into focused libraries; pick what you need. The
"Android" column marks targets that cross-compile cleanly to the
Swift Android SDK; the rest are Apple-only.

| Product | Android | Contents |
|---|:---:|---|
| `SheetMusic` | ✓ | **Umbrella.** Re-exports `Core` + `MSCX` + `MusicXML` + `MIDI` + a small convenience façade. Most format-only consumers want this. |
| `SheetMusicCore` | ✓ | Score data model (Score, Part, Measure, Voice, Note, Chord, …) and the shared `SheetMusicError`. No format I/O. |
| `SheetMusicMSCX` | ✓ | MuseScore file I/O: `.mscx` / `.mscz` read + write, including brackets, harmony / chord symbols, articulations, ornaments, MS3-compatibility export (`MSCXEncoderOptions(targetVersion: .v3)`). |
| `SheetMusicMusicXML` | ✓ | MusicXML import: `.musicxml` plain XML + `.mxl` zipped containers. |
| `SheetMusicMIDI` | ✓ | In-memory MIDI model, score → MIDI rendering, Standard MIDI File read + write. |
| `SheetMusicLoader` | ✓ | Single format-dispatch entry point: bytes → `Score` across `.mscx` / `.mscz` / `.musicxml` / `.mxl`. Exported so consumers that parse score files themselves (e.g. Android JNI libraries) never re-spell the format table. |
| `SheetMusicLayout` | ✓ | Pure-geometry layout engine. Foundation-only, no Apple frameworks. Talks to glyphs through a `FontMetricsProvider` DI seam so Apple hosts can wire CoreText and Android hosts can install a Bravura-measured SMuFL metrics table. |
| `SheetMusicAudioCore` | ✓ | Foundation-only audio value types (`PlaybackTimeline`, `MetronomeBeat`, `GMInstrument`, `MixerChannel`, `LoopRange`, `PlaybackState`, `AudioFileFormat`, …) shared between the Apple and Android playback engines. |
| `SheetMusicLayoutApple` |   | CoreText-backed `FontMetricsProvider` for `SheetMusicLayout`. Auto-installed by `SheetMusicUI` and `SheetMusicPDF`. |
| `SheetMusicUI` |   | SwiftUI read-only notation viewer (iOS 17+ / macOS 14+ / tvOS 17+). Bundles Bravura SMuFL font (SIL OFL). |
| `SheetMusicAudio` |   | Apple-only audio umbrella. Re-exports `SheetMusicAudioCore` + `SheetMusicAudioApple`. |
| `SheetMusicAudioApple` |   | AVAudioEngine-backed `PlaybackEngine` + audio-file export. Two multi-timbral AUMIDISynth units (melodic + percussion) behind an injectable `SynthBackend` seam, `SoundfontResolver` protocol, single-note preview, timeline-driven playback with chord-by-chord cursor via `PlaybackEngine.currentCursor`. |
| `SheetMusicAudioSwiftySynth` |   | Pure-Swift SoundFont2 `SynthBackend` (via [SwiftySynth](https://github.com/jiyimeta/swiftysynth)) — the default stealing-free synth for `PlaybackEngine`. |
| `SheetMusicPDF` | ✓ | PDF import via a pure-Swift reader (all platforms, including Android) + PDF export (Apple-only, iOS 17+ / macOS 14+). Import reads the PDF's vector content; add `SheetMusicOMRModel` for scanned pages. Export reuses `SheetMusicUI`'s layout + drawing pipeline through an `ImageRenderer` → `CGPDFContext` bridge, so glyphs stay vector. |
| `SheetMusicOMRModel` |   | The bundled optical music recognition model (~1.1 MB, compiled Core ML) that lets `SheetMusicPDF` read **scanned** (image-only) PDFs. Opt-in: `SheetMusicPDF` never depends on it, so a consumer that reads only typeset PDFs carries none of it. See [Scanned PDFs](#scanned-pdfs-omr). |

Android playback is delivered out-of-band as the
`io.github.jiyimeta:sheet-music-audio-android` Kotlin Gradle module
(`Android/SheetMusicAudioAndroid/`), which wraps FluidSynth + Oboe.
See [Android](#android).

### SoundFonts

`SheetMusicAudio` doesn't ship audio samples — you supply them via
`SoundfontResolver`. The example app expects:

* **Per-(bank, program) SF2 files** at `Sounds/BBB_PPP.sf2`, where
  `BBB` and `PPP` are three-digit decimal numbers (e.g.
  `Sounds/000_000.sf2` is bank 0 / program 0 = Acoustic Grand Piano).
  Loaded lazily so iPhone memory stays low — only the patches the
  score actually uses end up resident.
* **One or more full-GM `.sf2` files** dropped into `Sounds/`. The
  example app scans that directory at runtime and lists every full-GM
  font it finds in a picker (iOS: toolbar overflow menu; macOS:
  sidebar), so you can A/B a heavyweight font against a lighter one.
  Split files named `BBB_PPP.sf2` are treated as per-program lookups,
  not picker entries. The display name is derived from the file name
  (`_`/`-` → space); no specific file is required or hard-coded, and
  the first font (sorted by file name) is the default.

These SF2 files are **not distributed by this repository** — they are
too large to track in git and are not attached to this repo's Releases.
Obtain the split per-program set from
[jiyimeta/musescore-general-sf2-split](https://github.com/jiyimeta/musescore-general-sf2-split),
or supply your own General MIDI SoundFont(s). Drop them into
`Examples/Apple/SheetMusicExample/Sounds/`, regenerate the project
(`xcodegen` from `Examples/Apple/`), and rebuild — the example app picks
them up automatically.

> **SoundFont licensing.** `MuseScore_General` and `GeneralUser GS` are
> third-party works by S. Christian Collins, distributed under their own
> terms — see the
> [split-set repository](https://github.com/jiyimeta/musescore-general-sf2-split)
> and [schristiancollins.com](https://schristiancollins.com/generaluser.php).
> This package bundles no samples of its own; anyone redistributing a
> SoundFont binary must include its license text and attribution.

> `AVAudioUnitSampler` only reads `.sf2` and `.dls`, **not** `.sf3`
> (SF3 = SoundFont with OGG-compressed samples, which the system
> sampler does not decode). If you start from an `.sf3` distribution
> like the upstream MuseScore_General, convert to `.sf2` first
> (e.g. via Polyphone or `sf3convert`).

Without the soundfonts the example still runs — the playback
engine just stays silent, and you'll see the score without hearing
it. Library consumers who want a different layout (downloading at
runtime, bundling a smaller subset, etc.) implement
`SoundfontResolver` themselves.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jiyimeta/swift-sheet-music.git", from: "1.0.0"),
]
```

then depend on the products you need. Most consumers want the
`SheetMusic` umbrella (parsing + model + MIDI) and opt into rendering /
audio / PDF explicitly:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "SheetMusic", package: "swift-sheet-music"),
        // .product(name: "SheetMusicUI",    package: "swift-sheet-music"),
        // .product(name: "SheetMusicAudio", package: "swift-sheet-music"),
        // .product(name: "SheetMusicPDF",   package: "swift-sheet-music"),
    ]),
```

In Xcode, use **File ▸ Add Package Dependencies…** and paste the
repository URL. Requires Swift 6.2+ / Xcode 16+.

### Platform support

| Platform | Minimum | Coverage |
|---|---|---|
| iOS | 17 | full — model, formats, MIDI, layout, SwiftUI, audio, PDF |
| macOS | 14 | full |
| tvOS | 17 | model, formats, MIDI, layout, SwiftUI, audio (no PDF) |
| watchOS | 10 | model, formats, MIDI, layout (UI / audio / PDF are iOS / macOS / tvOS only) |
| Android | API 28 | Foundation-only subset (Core / MSCX / MusicXML / MIDI / Loader / Layout / AudioCore / EditWire / PDF import of typeset PDFs; scanned-PDF reading is Apple-only) via the Swift Android SDK + Kotlin AAR — see [Android](#android) |

## Example

```swift
import SheetMusic

let data  = try Data(contentsOf: someMscxURL)
let score = try SheetMusic.loadScore(mscxData: data)
let midi  = try SheetMusic.exportMIDI(score: score)
try midi.write(to: someOutputMIDIURL)
```

Round-trip a score back to MuseScore format after editing the model:

```swift
let score = try SheetMusic.loadScore(mscxURL: input)
// … mutate `score` …
try SheetMusic.exportMSCX(score, to: outputMSCX)
// or, packaged as a .mscz archive:
try SheetMusic.exportMSCZ(score, to: outputMSCZ)
```

`MSCXEncoderOptions(targetVersion: .v3)` produces MuseScore-3.6.2-flavoured `.mscx` / `.mscz`; `.v4` (default) keeps the current MuseScore-4 wire form.

If you only need the score model:

```swift
import SheetMusicCore   // just the Score / Note / Measure / … types
```

If you only need parsing or only MIDI:

```swift
import SheetMusicMSCX
let score = try MSCXParser.parse(mscxData)

import SheetMusicMIDI
let midiFile = try MidiRenderer.render(score: score)
let bytes    = try MidiWriter.write(midiFile)
```

To display a score in SwiftUI (iOS 17+ / macOS 14+):

```swift
import SheetMusic
import SheetMusicUI

let score = try SheetMusic.loadScore(mscxData: data)
ScoreView(score: score)
```

To play a score with a moving cursor (iOS 17+ / macOS 14+):

```swift
import SheetMusic
import SheetMusicAudio
import SheetMusicUI
import SwiftUI

struct PlayerView: View {
    let score: Score
    @StateObject private var engine = PlaybackEngine(
        soundfontResolver: MyResolver())

    var body: some View {
        VStack {
            ScoreView(
                score: score,
                playbackCursor: engine.currentCursor)
            HStack {
                Button(engine.state == .playing ? "Pause" : "Play") {
                    engine.state == .playing
                        ? engine.pause()
                        : engine.play(in: score)
                }
                Button("Stop") { engine.stop() }
            }
        }
        .task {
            try? engine.prepare(score: score)
        }
    }
}
```

`engine.currentCursor` is a `@Published` `ScoreCursor?` that ticks
chord-by-chord during playback (and on every metric beat in
between); `ScoreView` translates it into a tall translucent
rectangle spanning every staff in the system that contains the
current column.

To export a `Score` to PDF (iOS 17+ / macOS 14+):

```swift
import SheetMusic
import SheetMusicPDF

let score = try SheetMusic.loadScore(mscxData: data)
let pdf = try await Task { @MainActor in
    try PDFExporter.export(
        score: score,
        options: .init(
            pageSize: PDFExporter.Options.a4,
            margin: 36,
            staffSize: 14,
            title: "My Piece"))
}.value
try pdf.write(to: someOutputPdfURL)
```

`PDFExporter` is `@MainActor` (it drives SwiftUI's `ImageRenderer`).
The same drawing pipeline that paints `ScoreView` on screen paints
the PDF — so the printed pages match the on-screen layout exactly,
glyphs are vector, and a single set of options covers both surfaces.

### Scanned PDFs (OMR)

`PDFImporter` reads the *vector* content of a PDF — the glyphs and
paths a notation program wrote. A scanned or photographed score has
none: every page is one image. To read those, link `SheetMusicOMRModel`
(iOS 17+ / macOS 14+) and hand its classifier to the importer:

```swift
import SheetMusicOMRModel
import SheetMusicPDF

var options = PDFImportOptions()
options.omrTileClassifier = try CoreMLTileClassifier()
let score = try PDFImporter.parse(pdfURL: url, options: options)
```

The decision is made per page: a page the vector walker finds music on
is read exactly as before, and every other page — a scan, but also a
text-only cover page — is rasterized (300 dpi by default —
`omrRenderDPI`) and run through the detector, which costs roughly a
second and a half per page in a Release build and far more in Debug.
With `omrTileClassifier` left `nil`, the default, nothing changes: no
rasterization, no model load, no new code path.
`parseWithGeometry` takes the same fallback; its geometry side-car
carries no rects for the pages read this way, and says so in an `info`
diagnostic.

What comes through from a scanned page: notes, rests, chords, beams,
clefs, key and time signatures, accidentals, ties, tuplets, barlines
and the system structure. What does not, yet:

- **Text.** There is no OCR — no title, lyrics, tempo text or
  instrument names from a scanned page.
- **Android.** The detector's Core ML half is Apple-only. The portable
  half (tiling, decoding, and assembling detections with the
  classical-CV staff lines, stems and beams) already ships in
  `SheetMusicPDF` behind the `OMRTileClassifier` protocol; an ONNX
  implementation of that one protocol is what Android needs.
- **Real scans, measured.** Every accuracy number comes from synthetic
  scans — MuseScore renders degraded with noise, blur, skew and uneven
  illumination. Over 657 scores rendered, rasterized and read back,
  the median score keeps 94.1 % of its pitches and 91.9 % of its
  durations, against 99.2 % / 99.5 % for the same PDFs read as vectors.
  What is still open, and what has been measured and closed, is
  `docs/omr-open-work.md`.

Diagnostics (`PDFImportOptions.diagnostics`) name every page that was
rasterized, every page that could not be read, and — on the entry
points that never rasterize, `parseUsingSwiftReader` and the Android
entry — that the classifier was ignored.

The model is trained by the pipeline under `Training/` on
procedurally generated and public-domain scores only; see
`Training/README.md` for regenerating it.

## Android

The Foundation-only subset of the package (Core / MSCX / MusicXML /
MIDI / Loader / Layout / AudioCore / EditWire / PDF import)
cross-compiles to Android via the
[Swift 6.3 official Android SDK](https://www.swift.org/install/). Two
companion Kotlin Gradle modules under `Android/` ship as `.aar`
artifacts to GitHub Packages:

| Maven artifact | Contents |
|---|---|
| `io.github.jiyimeta:sheet-music-android` | JNI bridge + bundled `libSheetMusicJNI.so`. Score load, layout, draw-program emit. |
| `io.github.jiyimeta:sheet-music-audio-android` | FluidSynth (via [VolcanoMobile's `.aar`](https://github.com/VolcanoMobile/fluidsynth-android)) + [Oboe](https://github.com/google/oboe) low-latency PCM. Mirrors `PlaybackEngine` API on the Kotlin side. |
| `io.github.jiyimeta:sheet-music-compose-android` | Compose rendering, playback overlays, and generated draw-program codecs. |

The published artifacts are at **v1.0.0**. Consuming them in your own
Android app needs a `read:packages` PAT and a one-time `swiftkit-core`
publish to Maven local — see
[`Android/SheetMusicAndroid/README.md`](Android/SheetMusicAndroid/README.md)
for the complete `settings.gradle.kts` recipe and packaging config.

The instructions below (`Scripts/android-build-libs.sh` etc.) are for
**building this repository itself**, not for consuming the published AAR.
A working Compose demo lives at `Examples/Android/` (Pixel 6 Pro
API 36 verified). Bootstrap is documented in
[`docs/development/android.md`](docs/development/android.md) —
the short form:

```bash
# Build the native libs into Android/SheetMusicAndroid/src/main/jniLibs/
Scripts/android-build-libs.sh

# Resolve the wirelet codegen dep (used by the Android Gradle plugin)
swift package resolve

# Open Android/ or Examples/Android/ in Android Studio and Run
```

## Browser (WebAssembly)

The same engraver runs in a browser. `Web/sheet-music-web` is an npm package
wrapping the wasm build with a Canvas2D renderer; see
[its README](Web/sheet-music-web/README.md) for the consumer-side API, and
[`Examples/Web/`](Examples/Web/) for a viewer you can open locally.

The bindings expose display, playback and editing: `beginEditing()`, the typed
`applyEdit(intent)`, the `applyEditIntentBytes(bytes)` relay for intents authored
elsewhere, `undo()` / `redo()` and `editState()`. The browser replays the same
byte-pinned golden chains as Swift and Kotlin — including the ninety-two-step
edit-command parity chain — so a command behaves identically on all three.

```bash
Scripts/wasm-build-web.sh                    # wasm + JavaScript glue
npm --prefix Web/sheet-music-web install
npm --prefix Web/sheet-music-web run build
Scripts/web-example-serve.sh                 # http://localhost:8080/Examples/Web/
```

The download is about 2.4 MB brotli. Cross-compiling needs the same swift.org
toolchain the Android build does, plus the WebAssembly SDK and `binaryen`. See
[`docs/development/webassembly.md`](docs/development/webassembly.md) for the
contributor workflow and size gates.

### Toolchain: cross-compiling needs the swift.org Swift, not Xcode's

Building for Apple platforms works with whatever Swift ships in Xcode.
**Cross-compiling does not.** Apple's fork rejects the Android SDK's
pre-built Foundation module (`compiled module was created by a different
version of the compiler`), so a Swift SDK build needs the open-source
[swift.org toolchain](https://www.swift.org/install/macos/) — and the
toolchain and SDK versions have to match exactly.

Install the `.pkg` — double-clicking it puts the toolchain in
`/Library/Developer/Toolchains/` and asks for an administrator password.
There is a per-user install that does not:

```bash
installer -pkg swift-6.3.3-RELEASE-osx.pkg -target CurrentUserHomeDirectory
# → ~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain
```

Either location works; Xcode and the scripts here read both. Then **put
it first on `PATH`** — do not use `TOOLCHAINS`, which the `swiftly` shim
ignores if you have swiftly installed:

```bash
export PATH="$(Scripts/swift-org-toolchain.sh):$PATH"
swift --version
```

The version banner is how you tell the two apart, and it is worth
checking before assuming a build failure is real:

| banner | which Swift | cross-compiles? |
|---|---|---|
| `Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 …)` | Xcode's fork | no |
| `Apple Swift version 6.3.3 (swift-6.3.3-RELEASE)` | swift.org build | yes |

`Scripts/swift-org-toolchain.sh` is what resolves the two locations —
system first, then per-user — and prints the `usr/bin` path or exits 1.
`Scripts/android-build-libs.sh`, `Scripts/android-test.sh` and
`Scripts/preflight.sh` call it and prepend the result themselves, so they
work without the `export`. Ad-hoc `swift build --swift-sdk …` invocations
do not.

Install the Android SDK with the matching toolchain version:

```bash
swift sdk install \
    https://download.swift.org/swift-6.3.3-release/android-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_android.artifactbundle.tar.gz \
    --checksum d160cc3206dd1886dae3fef2337af5e25ec034692cd0ec225721c56cc69da7f5
```

`swift sdk list` should then report `swift-6.3.3-RELEASE_android`. The
NDK sysroot also needs a one-time setup step (NDK r27d or later) — see
[`docs/development/android.md`](docs/development/android.md) for that and for
the `WIRELET_PAT` / `gpr.key` credentials the Gradle side needs.

Local development also expects `swiftlint`, `swiftformat` and
`pre-commit` on `PATH` (`brew install swiftlint swiftformat pre-commit`);
the repository's pre-commit hooks run the first two on every commit.

Android codegen relies on the
[`io.github.jiyimeta.wirelet`](https://github.com/jiyimeta/swift-wirelet)
Gradle plugin to generate Kotlin codecs from Swift `@WireFormat`
sources. The plugin + runtime resolve from GitHub Packages — set
`gpr.user` / `gpr.key` in `~/.gradle/gradle.properties` (a classic
GitHub PAT with `read:packages` scope) before running any Gradle
task. Supported ABIs: `arm64-v8a`, `x86_64`. Lowest API level: 28.

Format support on Android matches Apple: `.mscz`, `.mscx`,
`.musicxml`, `.mxl` all parse. Glyph rendering on Android is
SMuFL-aware: `BravuraMetricsBuilder.buildTable` measures a Bravura
metrics table on the Kotlin side and installs it via
`SheetMusicJNI.nativeInstallSMuFLMetrics` (see
[`Android/SheetMusicAndroid/README.md`](Android/SheetMusicAndroid/README.md)).
Absent that install, layout falls back to a `StubFontMetricsProvider`
rectangle approximation, which also mis-centres articulations, fermatas
and breath marks by about 1.2 staff spaces — the table carries the
face's own ascent and descent, and the stub guesses them.

## Coverage

All 12 enabled cases of MuseScore's own `midiexport_tests.cpp` pass via
semantic-equivalence comparison: `midi01`–`midi03`, `midiPortExport`,
`midiArpeggio`, `midiMutedUnison`, `midiMeasureRepeats`,
`testInitialKeySigThenRepeatToMeas2`, `testRepeatsWithKeySigs`,
`testRepeatsWithKeySigsExceptFirstMeas`, `testVoltaTemp`, `testVoltaDynamic`.

Major features supported by the renderer:

- multi-staff / multi-part scores, with per-instrument MIDI channel/port
- per-staff line counts (`<StaffType><lines>`), e.g. 1- and 3-line
  percussion staves, with line-count-aware barline spans, ledger-line
  bounds, rest placement and percussion-clef / time-signature centering
- multiple `<Channel>` flavours per instrument (normal, pizzicato, …)
- multi-voice measures with same-pitch overlap resolution ("muted unison")
- `<startRepeat>` / `<endRepeat>` expansion + Volta-aware playback filtering
- `<MeasureRepeat>` groups (single- and multi-measure repeat icons)
- arpeggios (formula-faithful to MuseScore's `compatmidirender.cpp`)
- mid-piece tempo / dynamic / key-signature / time-signature changes
- iteration-boundary tempo and dynamic state reset
- gateTime, dotted notes, full-measure rests
- articulations (staccato / staccatissimo / accent / marcato / tenuto), with both layout placement and per-note velocity / gateTime offsets
- hairpins (crescendo / decrescendo) as continuous MIDI velocity ramps
- fermatas, ornaments (trill / mordent / turn), grace notes, tremolo, glissando
- per-note play flag (muted notes emit no MIDI), MS3 export round-trip

## Contributing

Contributions are welcome. This is a solo-maintained project, so for
anything substantial please open an issue to discuss it before sending a
pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development
setup, coding conventions, and the pre-merge verification workflow, and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations. High-level
design rationale lives in [ARCHITECTURE.md](ARCHITECTURE.md).

## Licensing

- **Source code (`Sources/`)**: MIT — see [LICENSE](LICENSE).
- **OMR model (`Sources/SheetMusicOMRModel/Resources/`) and its training
  pipeline (`Training/`)**: MIT. The model is trained on synthetic renders
  of procedurally generated and public-domain scores; no third-party
  score data is bundled or was used.
- **Test fixtures (`Tests/SheetMusicTests/Resources/`)**: GPL-3.0, copied
  from the upstream MuseScore repository — except the hand-authored
  fixtures listed as MIT in that directory's own notice, which is
  authoritative for the per-file split. See
  [Tests/SheetMusicTests/Resources/LICENSE](Tests/SheetMusicTests/Resources/LICENSE).
- See [NOTICE](NOTICE) for full provenance and trademark disclosure.

The Swift implementation is independently authored. Algorithms were
studied from MuseScore's C++ source
(<https://github.com/musescore/MuseScore>, GPL-3.0) and reimplemented
in Swift; no C++ source is reproduced. MuseScore is a trademark of
Muse Group.
