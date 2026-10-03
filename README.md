# swift-sheet-music

[![CI](https://github.com/jiyimeta/swift-sheet-music/actions/workflows/ci.yml/badge.svg)](https://github.com/jiyimeta/swift-sheet-music/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20Android%20%7C%20Windows-blue.svg)](#installation)
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
`.aar`. See [Android](#android) below. The same subset builds natively
on Windows (x64), where two Windows-only libraries draw a score with
Direct2D and play it through FluidSynth and WASAPI. See
[Windows](#windows).

> **Status:** unofficial. Not affiliated with MuseScore Limited / Muse Group,
> nor with Apple's `MusicKit` framework (which is for Apple Music integration).

## Libraries

The package is split into focused libraries; pick what you need. The
"Android" column marks targets that cross-compile cleanly to the
Swift Android SDK, and the "Windows" column the targets that build on
a Windows host. The two `…Windows` products at the end are
Windows-only; every other unmarked target is Apple-only.

| Product | Android | Windows | Contents |
|---|:---:|:---:|---|
| `SheetMusic` | ✓ | ✓ | **Umbrella.** Re-exports `Core` + `MSCX` + `MusicXML` + `MIDI` + a small convenience façade. Most format-only consumers want this. |
| `SheetMusicCore` | ✓ | ✓ | Score data model (Score, Part, Measure, Voice, Note, Chord, …) and the shared `SheetMusicError`. No format I/O. |
| `SheetMusicMSCX` | ✓ | ✓ | MuseScore file I/O: `.mscx` / `.mscz` read + write, including brackets, harmony / chord symbols, articulations, ornaments, MS3-compatibility export (`MSCXEncoderOptions(targetVersion: .v3)`). |
| `SheetMusicMusicXML` | ✓ | ✓ | MusicXML import: `.musicxml` plain XML + `.mxl` zipped containers. |
| `SheetMusicMIDI` | ✓ | ✓ | In-memory MIDI model, score → MIDI rendering, Standard MIDI File read + write. |
| `SheetMusicLoader` | ✓ | ✓ | Single format-dispatch entry point: bytes → `Score` across `.mscx` / `.mscz` / `.musicxml` / `.mxl`. Exported so consumers that parse score files themselves (e.g. Android JNI libraries) never re-spell the format table. |
| `SheetMusicLayout` | ✓ | ✓ | Pure-geometry layout engine. Foundation-only, no Apple frameworks. Talks to glyphs through a `FontMetricsProvider` DI seam so Apple hosts can wire CoreText, Android hosts can install a Bravura-measured SMuFL metrics table, and Windows hosts install the same table plus DirectWrite for the system face. |
| `SheetMusicAudioCore` | ✓ | ✓ | Foundation-only audio value types (`PlaybackTimeline`, `MetronomeBeat`, `GMInstrument`, `MixerChannel`, `LoopRange`, `PlaybackState`, `AudioFileFormat`, `MixLevel`, `MasterOutputStage`, …) shared between the Apple, Android and Windows playback engines. |
| `SheetMusicEditWire` | ✓ | ✓ | The one declaration of the edit wire: `EditIntentCodec` turns an `EditIntent` into TLV bytes and back, alongside the codecs for the identity and geometry types an intent names. For a host that has to put an edit on a wire rather than apply it locally — an Android mirror session, the browser bridge, a networked peer replicating an edit. The choice indices are append-only; see [Contributing](CONTRIBUTING.md). |
| `SheetMusicZip` | ✓ | ✓ | `ZipWriter` / `ZipReader` / `ZipCompressionMethod`, for a host that must write a zip which is not an `.mscz` and so has no `.mscx` to hand `MSCZWriter`. Apple uses `Compression`; Linux and Android link the system libz; the WebAssembly and Windows builds use a vendored raw-DEFLATE subset. |
| `SheetMusicLayoutApple` |   |   | CoreText-backed `FontMetricsProvider` for `SheetMusicLayout`. Auto-installed by `SheetMusicUI` and `SheetMusicPDF`. |
| `SheetMusicUI` |   |   | SwiftUI read-only notation viewer (iOS 17+ / macOS 14+ / tvOS 17+). Bundles Bravura SMuFL font (SIL OFL). |
| `SheetMusicAudio` |   |   | Apple-only audio umbrella. Re-exports `SheetMusicAudioCore` + `SheetMusicAudioApple`. |
| `SheetMusicAudioApple` |   |   | AVAudioEngine-backed `PlaybackEngine` + audio-file export. Two multi-timbral AUMIDISynth units (melodic + percussion) behind an injectable `SynthBackend` seam, `SoundfontResolver` protocol, single-note preview, timeline-driven playback with chord-by-chord cursor via `PlaybackEngine.currentCursor`. |
| `SheetMusicAudioSwiftySynth` |   |   | Pure-Swift SoundFont2 `SynthBackend` (via [SwiftySynth](https://github.com/jiyimeta/swiftysynth)) — the default stealing-free synth for `PlaybackEngine`. |
| `SheetMusicPDF` | ✓ | ✓ | PDF import via a pure-Swift reader (all platforms, including Android and Windows) + PDF export (Apple-only, iOS 17+ / macOS 14+). Import reads the PDF's vector content; add `SheetMusicOMRModel` for scanned pages. Export reuses `SheetMusicUI`'s layout + drawing pipeline through an `ImageRenderer` → `CGPDFContext` bridge, so glyphs stay vector. |
| `SheetMusicOMRModel` |   |   | The bundled optical music recognition model (~1.1 MB, compiled Core ML) that lets `SheetMusicPDF` read **scanned** (image-only) PDFs. Opt-in: `SheetMusicPDF` never depends on it, so a consumer that reads only typeset PDFs carries none of it. See [Scanned PDFs](#scanned-pdfs-omr). |
| `SheetMusicRenderWindows` |   | ✓ | Windows-only. `ScorePages` lays a score out into pages and `ScoreSurface` draws them onto a composition swap chain for a XAML `SwapChainPanel` through Direct2D + DirectWrite; `installWindowsFontMetrics()` sets up the layout's font metrics. Bundles Bravura, the Edwin faces (SIL OFL) and their metrics table. See [Windows](#windows). |
| `SheetMusicAudioWindows` |   | ✓ | Windows-only. `WindowsPlaybackEngine`: the Apple `PlaybackEngine`'s operations over FluidSynth + WASAPI, following the default output device. Links the FluidSynth DLL. See [Windows](#windows). |

Android playback is delivered out-of-band as the
`io.github.jiyimeta:sheet-music-audio-android` Kotlin Gradle module
(`Android/SheetMusicAudioAndroid/`), which wraps FluidSynth + Oboe.
See [Android](#android). Windows playback is `SheetMusicAudioWindows`
above; see [Windows](#windows).

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
| Windows | 10 (22H2) and later, x64 | the same Foundation-only subset as Android, plus on-screen drawing (`SheetMusicRenderWindows`) and playback (`SheetMusicAudioWindows`); no PDF export, audio-file export or scanned-PDF reading — see [Windows](#windows) |

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
SMuFL-aware: `FontMetricsBuilder.buildTable` measures Bravura and Edwin
on the Kotlin side and installs the pair via
`SheetMusicJNI.nativeInstallFontMetrics` (see
[`Android/SheetMusicAndroid/README.md`](Android/SheetMusicAndroid/README.md)).
Absent that install, layout falls back to a `StubFontMetricsProvider`
rectangle approximation, which mis-centres articulations, fermatas
and breath marks by about 1.2 staff spaces — the table carries each
face's own ascent and descent, and the stub guesses them — and sizes
every lyric, harmony and rehearsal-mark frame off bucket-average
advances rather than the font's own.

## Windows

The Foundation-only subset Android builds (Core / MSCX / MusicXML /
MIDI / Loader / Layout / AudioCore / EditWire / Zip / PDF import)
builds natively on a Windows host. There is nothing to cross-compile
and no environment variable to set: the manifest sees the host. Two
Windows-only products add what a Windows app needs to show and play a
score:

| Product | Contents |
|---|---|
| `SheetMusicRenderWindows` | `ScorePages`: a score laid out per `ScorePageOptions` and cut into pages, and the same pages with a selection tinted. `ScoreSurface`: those pages on a composition swap chain, rasterized into tiles from each system's commands and blitted every frame with the app's overlays (cursor, selection) on top; rebuilt after a device loss. `installWindowsFontMetrics()`. `Direct2DPageRenderer.renderPNG(pages:page:pxPerMM:fontFiles:to:)` for one page as a PNG. Bravura, the Edwin faces and their metrics table bundled. Direct2D + DirectWrite. |
| `SheetMusicAudioWindows` | `WindowsPlaybackEngine`: the Apple `PlaybackEngine`'s operations under the same names — prepare / replace the score / reload the SoundFont, transport, loops, rate / transposition / tuning, the mixer with its metronome strip, master gain and output stage, level monitoring, note previews — plus events for the end of the score and a lost / recovered output device. FluidSynth + WASAPI; follows the default output device. |

Not on Windows in 4.0.0: PDF export and scanned-PDF reading (Apple-only,
as on Android), audio-file export, and arm64.

### Requirements

- **Windows 10 (22H2) or later on x64.** Releases are verified on Windows 10 Pro 22H2; Windows 11 is expected to work but is not what the gate runs on. arm64 has not been built or tested.
- **The swift.org Swift 6.3.3 toolchain** for Windows
  ([install](https://www.swift.org/install/windows/)), with the Visual
  Studio components its installer asks for (the MSVC x64 build tools
  and a Windows SDK). Direct2D, DirectWrite, Direct3D 11, WIC and
  WASAPI come with the Windows SDK; drawing needs nothing else.
- **FluidSynth**, for `SheetMusicAudioWindows` only — below.

### FluidSynth

`SheetMusicAudioWindows` links FluidSynth 2 dynamically, as the Android
module does. Use the official Windows release zip in its `cpp11` flavor
(x64, no glib; verified with 2.6.1), unpack it, and pass its `include`
and `lib` directories to every build of a package that depends on
`SheetMusicAudioWindows`:

```powershell
$fluidsynth = 'C:\fluidsynth'   # the unpacked release zip
swift build -Xcc "-I$fluidsynth\include" -Xlinker "-L$fluidsynth\lib"
```

The target links the zip's import library, `libfluidsynth-3`. At run
time `libfluidsynth-3.dll` and the DLLs it depends on from the zip's
`bin` directory must sit beside your executable (or on `PATH`).
FluidSynth is LGPL 2.1 and is linked as a DLL, never statically; ship
its license text alongside it.

### Bundled fonts and metrics

`SheetMusicRenderWindows` carries the five faces it draws with and the
metrics table the layout measures them by as SwiftPM resources.
`swift build` puts them in a folder named
`swift-sheet-music_SheetMusicRenderWindows.resources` beside your
executable, and `Bundle.module` finds them there (or, failing that, in
the build directory). **A deployed app must ship that folder beside its
executable too** — in its MSIX, zip or installer — or the first call
that needs it (`ScoreSurface()`, `installWindowsFontMetrics()`) stops
the process: SwiftPM's generated accessor calls `fatalError`.

### What the host does

1. **Font metrics, once, before the first layout.** Call
   `installWindowsFontMetrics()`. It installs `sheet-music.smft` — the
   measured Bravura and Edwin table, bundled with the module so it
   always matches the package revision — and measures Segoe UI — the
   face notation labels are laid out and drawn in on Windows — with
   DirectWrite, so a label ends where the layout anchored it. A host
   that ships its own table passes its bytes to
   `installWindowsFontMetrics(tableBytes:)` instead.
2. **Layout.** `ScorePages.compute(score:pageWidthMM:pageHeightMM:options:)`
   lays the score out per a `ScorePageOptions` — the mode (vertical,
   horizontal or page), the staff size, hidden staves, clef overrides,
   transposition and the rest of what the Android bridge takes,
   typed, `nil` where it means "the engine's own" — and cuts it
   into pages. It keeps the `LayoutDocument` and the filtered score it
   laid out, and `tinted(argb:ids:)` gives the same pages with a
   selection drawn in a color, without laying the score out again.
   The pages' draw commands stay inside the package. For pages that
   match the Apple page deck, set `pageMarginsMM` to
   `.uniform(12.7)` on A4 and lay the pages out by `pageSizeMM(_:)`,
   which is wider than A4 when the music overflows the margins.
3. **Drawing.** Create a `ScoreSurface()`. It draws with the faces
   bundled with the module: Bravura and the four Edwin faces — roman,
   italic, bold and bold italic, since bold and italic are never
   synthesized — all SIL OFL, their license texts beside them
   (`ScoreSurface.bundledFontFiles` lists their paths, for
   `Direct2DPageRenderer.renderPNG`). Segoe UI comes from the system. A
   host that ships its own copies passes them to
   `ScoreSurface(fontFiles:)`. `attach(widthDIP:heightDIP:compositionScaleX:compositionScaleY:)`
   returns an `IDXGISwapChain1` holding a reference: pass it to your
   `SwapChainPanel`'s `ISwapChainPanelNative::SetSwapChain`, then
   release it. Forward `SizeChanged` and `CompositionScaleChanged` to
   `resize(…)`, and hand the `ScorePages` to `setPages(_:)` — again
   after an edit or a new tint: pages of the same count and sizes redraw
   only the systems that changed. Call `draw(_:)` with a
   `ScoreSurface.Frame` — `pxPerMM` (zoom × composition scale × 96 /
   25.4), the document origin, each page's origin and overlays such as
   the playback cursor (`.fillRect` / `.strokeRect` on a `PageRectMM`,
   in the page's millimetres) — from `CompositionTarget.Rendering`
   while something moves, and otherwise only when the view changes.
   `.deviceRecreated(newSwapChain:)` means the device was lost and
   rebuilt: attach the new swap chain the same way. Use a surface on
   the UI thread that created it. The package itself does not depend
   on the Windows App SDK.
4. **Playback.** `WindowsPlaybackEngine(soundfontResolver:metronomeClickProvider:)`
   takes the same calls as the Apple `PlaybackEngine` —
   `prepare(score:)`, `play(from:in:countIn:)`, `seek(to:)`,
   `setLoop(from:to:)`, `setRate(_:)`, the mixer — from one thread. The
   score plays through the resolver's `defaultGMSoundfontURL`, one
   General MIDI `.sf2`. `onEvent` (the end of the score, the output
   device lost and recovered), `onOutputDeviceRemoved` (the device
   went away rather than a new default taking over — where the Apple
   hosts pause) and the level-monitoring handler run on the audio
   thread: hop to the UI before touching anything.

### How releases are verified

There is no Windows CI. Before a release, a manual gate runs on a
Windows machine (x64, 2-core Core i5):

- the whole package's build and tests;
- renderer parity against the Mac: the 30 sample scores drawn by
  Direct2D and by the Mac's CoreGraphics walk of the same pages;
- scripted playback checks (`windows-playback-probe`): drift against
  the rendered audio, seeks, loops, rate, count-in, mixer read-backs,
  a preview right after a pause, and a forced device loss and removal;
- the on-screen frame budget (`windows-render-probe --onscreen`): first
  frame, scroll, zoom, a 60 fps playback cursor, memory at 200 %, the
  tiled frame against an untiled render, and a forced device loss.

The two probes are declared only when
`SWIFT_SHEET_MUSIC_WINDOWS_PROBES=1` is set, so a package that depends
on this one builds neither.

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
