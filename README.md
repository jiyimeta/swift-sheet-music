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
| `SheetMusicLayout` | ✓ | Pure-geometry layout engine. Foundation-only, no Apple frameworks. Talks to glyphs through a `FontMetricsProvider` DI seam so Apple hosts can wire CoreText and Android hosts can wire a `Paint`-based provider. |
| `SheetMusicAudioCore` | ✓ | Foundation-only audio value types (`PlaybackTimeline`, `MetronomeBeat`, `GMInstrument`, `MixerChannel`, `LoopRange`, `PlaybackState`, `AudioFileFormat`, …) shared between the Apple and Android playback engines. |
| `SheetMusicLayoutApple` |   | CoreText-backed `FontMetricsProvider` for `SheetMusicLayout`. Auto-installed by `SheetMusicUI` and `SheetMusicPDF`. |
| `SheetMusicUI` |   | SwiftUI read-only notation viewer (iOS 17+ / macOS 14+ / tvOS 17+). Bundles Bravura SMuFL font (SIL OFL). |
| `SheetMusicAudio` |   | Apple-only audio umbrella. Re-exports `SheetMusicAudioCore` + `SheetMusicAudioApple`. |
| `SheetMusicAudioApple` |   | AVAudioEngine-backed `PlaybackEngine` + audio-file export. Per-staff `AVAudioUnitSampler`s, `SoundfontResolver` protocol, single-note preview, timeline-driven playback with chord-by-chord cursor via `PlaybackEngine.currentCursor`. |
| `SheetMusicPDF` |   | PDF export (iOS 17+ / macOS 14+). Reuses `SheetMusicUI`'s layout + drawing pipeline through an `ImageRenderer` → `CGPDFContext` bridge, so glyphs stay vector. |

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
* **`Sounds/MuseScore_General.sf2`** — full GM SoundFont fallback
  for any (bank, program) without a dedicated file.

Both are distributed via GitHub Releases (the SF2 files are too
large to track in git). The split per-program SF2 set lives at
[jiyimeta/musescore-general-sf2-split](https://github.com/jiyimeta/musescore-general-sf2-split).
Download the release archive, unzip into
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
    .package(url: "https://github.com/jiyimeta/swift-sheet-music.git", from: "0.1.0"),
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
| Android | API 28 | Foundation-only subset (Core / MSCX / MusicXML / MIDI / Layout / AudioCore) via the Swift Android SDK + Kotlin AAR — see [Android](#android) |

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

## Android

The Foundation-only subset of the package (Core / MSCX / MusicXML /
MIDI / Layout / AudioCore) cross-compiles to Android via the
[Swift 6.3 official Android SDK](https://www.swift.org/install/). Two
companion Kotlin Gradle modules under `Android/` ship as `.aar`
artifacts to GitHub Packages:

| Maven artifact | Contents |
|---|---|
| `io.github.jiyimeta:sheet-music-android` | JNI bridge + bundled `libSheetMusicJNI.so`. Score load, layout, draw-program emit. |
| `io.github.jiyimeta:sheet-music-audio-android` | FluidSynth (via [VolcanoMobile's `.aar`](https://github.com/VolcanoMobile/fluidsynth-android)) + [Oboe](https://github.com/google/oboe) low-latency PCM. Mirrors `PlaybackEngine` API on the Kotlin side. |

A working Compose demo lives at `Examples/Android/` (Pixel 6 Pro
API 36 verified). Bootstrap is documented in `CLAUDE.md` —
the short form:

```bash
# Build the native libs into Android/SheetMusicAndroid/src/main/jniLibs/
Scripts/android-build-libs.sh

# Resolve the wirelet codegen dep (used by the Android Gradle plugin)
swift package resolve

# Open Android/ or Examples/Android/ in Android Studio and Run
```

Android codegen relies on the
[`io.github.jiyimeta.wirelet`](https://github.com/jiyimeta/swift-wirelet)
Gradle plugin to generate Kotlin codecs from Swift `@WireFormat`
sources. The plugin + runtime resolve from GitHub Packages — set
`gpr.user` / `gpr.key` in `~/.gradle/gradle.properties` (a classic
GitHub PAT with `read:packages` scope) before running any Gradle
task. Supported ABIs: `arm64-v8a`, `x86_64`. Lowest API level: 28.

Format support on Android matches Apple: `.mscz`, `.mscx`,
`.musicxml`, `.mxl` all parse. Glyph rendering on Android uses a
`StubFontMetricsProvider` rectangle approximation today — a
SMuFL-aware Android provider is a future phase.

## Coverage

All 12 enabled cases of MuseScore's own `midiexport_tests.cpp` pass via
semantic-equivalence comparison: `midi01`–`midi03`, `midiPortExport`,
`midiArpeggio`, `midiMutedUnison`, `midiMeasureRepeats`,
`testInitialKeySigThenRepeatToMeas2`, `testRepeatsWithKeySigs`,
`testRepeatsWithKeySigsExceptFirstMeas`, `testVoltaTemp`, `testVoltaDynamic`.

Major features supported by the renderer:

- multi-staff / multi-part scores, with per-instrument MIDI channel/port
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
- **Test fixtures (`Tests/SheetMusicTests/Resources/`)**: GPL-3.0, copied
  from the upstream MuseScore repository — see
  [Tests/SheetMusicTests/Resources/LICENSE](Tests/SheetMusicTests/Resources/LICENSE).
- See [NOTICE](NOTICE) for full provenance and trademark disclosure.

The Swift implementation is independently authored. Algorithms were
studied from MuseScore's C++ source
(<https://github.com/musescore/MuseScore>, GPL-3.0) and reimplemented
in Swift; no C++ source is reproduced. MuseScore is a trademark of
Muse Group.
