# CLAUDE.md

Project-specific guidance for Claude when working in this repository.

## What this is

`swift-sheet-music` is a Swift Package Manager library suite for working
with engraved music notation. It parses MuseScore (`.mscx`) files into a
typed Swift score model and exports the score to Standard MIDI Files. UI
and audio playback libraries are planned but not yet implemented.

The package is **unofficial**: not affiliated with MuseScore Limited /
Muse Group, nor with Apple's `MusicKit` framework.

## Library layout

Four library products live in this single package. Their dependency graph
is strictly top-down:

```
SheetMusic   (umbrella + small façade)
   │
   ├─→ SheetMusicCore     (Score data model, SheetMusicError; no I/O)
   ├─→ SheetMusicMSCX     (mscx parsing — XML + decoders;  → Core, ZIPFoundation)
   └─→ SheetMusicMIDI     (in-memory MIDI model, score→MIDI render, SMF I/O;  → Core)
```

`SheetMusic` re-exports the three sub-libraries with `@_exported import`
and adds a convenience façade `enum SheetMusic { static loadScore /
exportMIDI }`. Most consumers use `import SheetMusic`; advanced users can
take only `SheetMusicCore` (model only) or single format libraries.

Future libraries (already namespaced for): `SheetMusicUI` (SwiftUI views),
`SheetMusicPlayback` (AVAudioEngine), `SheetMusicMusicXML` / `SheetMusicPDF`
(other formats). When adding one, also re-export from `SheetMusic` and
update README's library table.

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
```

## Build / test / run

```bash
# Build & test the package
swift build
swift test                                      # 48 tests, 12 suites; should be 100% green
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
all four library products and uses `@testable import` on each
sub-library (re-exports do NOT transitively grant testable access).

```swift
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
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

## MuseScore submodule

`MuseScore/` is a git submodule referencing the upstream MuseScore C++
source (GPL-3.0). It exists for **development reference only** — to let
us cross-check algorithms against the C++ implementation. It is not
distributed as part of the SwiftPM package (consumers receive only
`Sources/`).

When researching a MuseScore behaviour, read it from the submodule and
implement independently in Swift; do not copy code structures verbatim.

## Things not to do

- Don't add the MuseScore submodule contents into the SwiftPM package
  (it's GPL — keep it dev-only).
- Don't introduce GPL code into `Sources/`. The published source is MIT.
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
