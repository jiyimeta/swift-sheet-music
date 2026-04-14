# swift-musescore-parser

A Swift package that parses MuseScore (`.mscx`) score files and exports
them to Standard MIDI Files. Built from scratch in Swift, with no direct
runtime dependency on the MuseScore application.

> **Status:** unofficial. Not affiliated with MuseScore Limited / Muse Group.

## Example

```swift
import MuseScoreParser

let data = try Data(contentsOf: someMscxURL)
let score = try MuseScoreParser.loadScore(mscxData: data)
let midi  = try MuseScoreParser.exportMIDI(score: score)
try midi.write(to: someOutputMIDIURL)
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
- **Test fixtures (`Tests/.../Resources/`)**: GPL-3.0, copied from the
  upstream MuseScore repository — see
  [Tests/MuseScoreParserTests/Resources/LICENSE](Tests/MuseScoreParserTests/Resources/LICENSE).
- See [NOTICE](NOTICE) for the full provenance and trademark disclosure.

The Swift implementation is independently authored. Algorithms were
studied from MuseScore's C++ source (referenced via the `MuseScore/` git
submodule) and reimplemented in Swift; no C++ source is reproduced.
MuseScore is a trademark of Muse Group.
