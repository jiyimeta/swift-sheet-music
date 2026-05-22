# swift-sheet-music

A Swift package for working with engraved music notation: parsing
MuseScore (`.mscx` / `.mscz`) score files, modelling them as Swift value
types, and exporting them back to MuseScore format or to Standard MIDI
Files. Built from scratch in Swift, with no direct runtime dependency
on the MuseScore application.

> **Status:** unofficial. Not affiliated with MuseScore Limited / Muse Group,
> nor with Apple's `MusicKit` framework (which is for Apple Music integration).

## Libraries

The package is split into focused libraries; pick what you need.

| Product | Contents |
|---|---|
| `SheetMusic` | **Umbrella.** Re-exports the libraries below + a small convenience façade. Most consumers want this. |
| `SheetMusicCore` | Score data model (Score, Part, Measure, Voice, Note, Chord, …) and the shared error type. No format I/O. |
| `SheetMusicMSCX` | MuseScore file I/O: `.mscx` / `.mscz` read and write (main score only). |
| `SheetMusicMIDI` | In-memory MIDI model, score → MIDI rendering, SMF read/write. |
| `SheetMusicUI` | SwiftUI read-only notation viewer (macOS 15+), bundles Bravura SMuFL font (SIL OFL). |
| `SheetMusicAudio` | AVAudioEngine-backed playback. Per-staff `AVAudioUnitSampler`s, `SoundfontResolver` protocol, single-note preview, and full timeline-driven playback (chord-by-chord cursor via `PlaybackEngine.currentCursor`). |
| `SheetMusicPDF` | PDF export (macOS 15+ / iOS 16+). Reuses `SheetMusicUI`'s layout + drawing pipeline through an `ImageRenderer` → `CGPDFContext` bridge, so glyphs stay vector. |

Future libraries on the roadmap: additional `SheetMusic<FormatName>`
libraries (e.g. MusicXML export) as they're added.

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

To display a score in SwiftUI (macOS 15+):

```swift
import SheetMusic
import SheetMusicUI

let score = try SheetMusic.loadScore(mscxData: data)
ScoreView(score: score)
```

To play a score with a moving cursor (macOS 13+ / iOS 16+):

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
                playbackCursor: engine.currentItem)
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

To export a `Score` to PDF (macOS 15+ / iOS 16+):

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
