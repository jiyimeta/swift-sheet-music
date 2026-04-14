# swift-sheet-music

A Swift package for working with engraved music notation: parsing
MuseScore (`.mscx`) score files, modelling them as Swift value types, and
exporting them to Standard MIDI Files. Built from scratch in Swift, with
no direct runtime dependency on the MuseScore application.

> **Status:** unofficial. Not affiliated with MuseScore Limited / Muse Group,
> nor with Apple's `MusicKit` framework (which is for Apple Music integration).

## Libraries

The package is split into focused libraries; pick what you need.

| Product | Contents |
|---|---|
| `SheetMusic` | **Umbrella.** Re-exports the libraries below + a small convenience façade. Most consumers want this. |
| `SheetMusicCore` | Score data model (Score, Part, Measure, Voice, Note, Chord, …) and the shared error type. No format I/O. |
| `SheetMusicMSCX` | MuseScore file I/O: `.mscx` parsing and `.mscz` read/write (main score only). |
| `SheetMusicMIDI` | In-memory MIDI model, score → MIDI rendering, SMF read/write. |

Future libraries on the roadmap: `SheetMusicUI` (SwiftUI score views),
`SheetMusicPlayback` (AVAudioEngine MIDI player), and additional
`SheetMusic<FormatName>` libraries (e.g. MusicXML, PDF) as they're added.

## Example

```swift
import SheetMusic

let data  = try Data(contentsOf: someMscxURL)
let score = try SheetMusic.loadScore(mscxData: data)
let midi  = try SheetMusic.exportMIDI(score: score)
try midi.write(to: someOutputMIDIURL)
```

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
studied from MuseScore's C++ source (referenced via the `MuseScore/` git
submodule) and reimplemented in Swift; no C++ source is reproduced.
MuseScore is a trademark of Muse Group.
