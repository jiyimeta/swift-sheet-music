# MSCX / MSCZ export — design

Status: proposed
Date: 2026-05-07
Target libraries: `SheetMusicMSCX`, `SheetMusicXMLTools`, `SheetMusic`

## Motivation

Today the package can parse `.mscx` / `.mscz` into a `Score` and render
the score to a Standard MIDI File. There is no way to write the score
*back* into MuseScore's own format. This spec adds the missing direction:
`Score → .mscx XML → .mscz package`.

`MSCZWriter` already packages caller-supplied `.mscx` bytes into a
minimal MSCZ archive (introduced in
`docs/superpowers/specs/2026-04-14-mscz-reading-writing-design.md`) and
explicitly defers `Score → mscx` encoding to a later spec. This is that
spec.

## Scope (vertical slice: midi01 round-trip)

Following the established `midi01` vertical-slice pattern, the success
criterion for this spec is:

> Parsing `Tests/SheetMusicTests/Resources/midi01.mscx` to a `Score`,
> encoding that `Score` back to `.mscx` bytes, and re-parsing those
> bytes yields a `Score` value that compares equal under `Equatable`
> to the original.

This is a **semantic** round-trip, mirroring the MIDI side's
`MidiSemanticComparison` philosophy. Byte-level equivalence with
MuseScore Studio's own writer is explicitly out of scope: whitespace,
attribute ordering, and the exact closing-tag indentation MuseScore
emits all differ harmlessly.

After Phase 1 lands, additional fixtures (key-signature changes, repeats,
arpeggios, harmony, …) are extended in subsequent specs by adding one
`MSCXEncoder+<Type>.swift` file per element class. Each extension is a
small, isolated change that does not touch the encoder façade.

## Non-goals

- **Byte-identical output** to MuseScore Studio. We target only a
  semantic round-trip through this library's parser.
- **Restoring information the parser dropped.** MuseScore's `.mscx` is a
  superset of what this library models (the parser is permissive: unknown
  `<voice>` children are silently skipped — see `MSCXDecoder+Voice.swift`).
  The encoder emits only what the `Score` model carries; anything the
  parser never recorded cannot be reconstituted.
- **MuseScore 3.x output.** The encoder targets the 4.x dialect that the
  current parser primarily handles (`<museScore version="4.60">`).
- **Auxiliary MSCZ resources** — `score_style.mss`, `chordlist.xml`,
  `Thumbnails/*`, `audio.ogg`, `audiosettings.json`,
  `viewsettings.json`, `Excerpts/*.mscx`. The MSCZ writer continues to
  emit a single `score.mscx` entry, matching the existing low-level
  `MSCZWriter`.
- **Phase 2 elements** in this spec. Spanners, harmony, dynamics,
  arpeggios, glissandos, fermatas, rehearsal marks, jumps/markers,
  lyrics, grace notes — all out of scope here. They land in follow-up
  specs once the encoder skeleton exists.
- **Async / streaming variants.** All I/O is synchronous, matching
  existing API.

## Architecture

```
Sources/SheetMusicXMLTools/
├── XMLTreeNode.swift          (existing; gains a small builder helper)
├── XMLTreeParser.swift        (unchanged)
└── XMLTreeSerializer.swift    (new: XMLTreeNode → Data, with escaping)

Sources/SheetMusicMSCX/
├── MSCXParser.swift           (unchanged)
├── MSCXEncoder.swift          (new: public façade — Score → Data, → URL)
├── MSCZReader.swift           (unchanged)
├── MSCZWriter.swift           (+ high-level write(score:) overloads)
├── Decoders/MSCXDecoder+*.swift  (unchanged)
└── Encoders/MSCXEncoder+*.swift  (new: one extension per element type)

Sources/SheetMusic/
└── SheetMusic.swift           (+ exportMSCX, exportMSCZ façade methods)
```

Dependency direction is unchanged. `SheetMusicXMLTools` already
underpins both parsing and (now) serialization, keeping XML escaping
and tree-walk concerns out of `SheetMusicMSCX`.

### Encoder split (one file per element)

Symmetrical with the existing `Decoders/MSCXDecoder+<Type>.swift` layout.
Phase-1 files (those midi01 actually exercises):

```
Encoders/MSCXEncoder+Score.swift          // <museScore><Score> root, metaTags, Division
Encoders/MSCXEncoder+Style.swift          // <Style> subset emitted from ScoreStyle
Encoders/MSCXEncoder+Part.swift           // <Part>, including nested Staff stub
Encoders/MSCXEncoder+Staff.swift          // <Staff> (top-level: measures + Staff-in-Part)
Encoders/MSCXEncoder+Instrument.swift     // <Instrument> + InstrumentArticulation/Channel
Encoders/MSCXEncoder+Measure.swift        // <Measure>, including <voice> sequencing
Encoders/MSCXEncoder+Voice.swift          // <voice> element ordering
Encoders/MSCXEncoder+Chord.swift          // <Chord> with durationType, notes
Encoders/MSCXEncoder+Note.swift           // <Note>
Encoders/MSCXEncoder+Rest.swift           // <Rest>
Encoders/MSCXEncoder+Clef.swift
Encoders/MSCXEncoder+TimeSignature.swift
Encoders/MSCXEncoder+KeySignature.swift
Encoders/MSCXEncoder+Tempo.swift
Encoders/MSCXEncoder+Misc.swift           // metaTag, eid, showInvisible, showFrames…
```

Each file owns a single static `static func encode(_:) -> XMLTreeNode`
extension on the corresponding model type (or a free function in the
`Misc` case). The 300-line SwiftLint cap stays comfortably honored.

### XML serialization

`XMLTreeNode` is currently a read-only view emitted by `XMLTreeParser`
but its struct is already mutable (`var children`, `var text`). It
becomes the encoder's intermediate representation: every encoder
returns an `XMLTreeNode`, and the façade serializes the root.

`XMLTreeSerializer` (new file, `SheetMusicXMLTools`):

- Emits UTF-8 with the standard XML prolog
  (`<?xml version="1.0" encoding="UTF-8"?>`).
- 2-space indent, one element per line (this is a deliberate
  divergence from MuseScore Studio's closing-tag indentation; bytes
  are not the contract — semantic round-trip is).
- Escapes `&`, `<`, `>` in text, plus `"` in attributes.
- Self-closes empty elements (`<foo/>`) when they have no text and
  no children.
- Preserves element ordering exactly as the encoder built it.

### Public API additions

```swift
// SheetMusicMSCX
public enum MSCXEncoder {
    /// Serialize a `Score` to `.mscx` XML bytes.
    public static func encode(_ score: Score) throws -> Data

    /// Serialize a `Score` and write the resulting `.mscx` to a file URL.
    public static func encode(_ score: Score, to url: URL) throws
}

// SheetMusicMSCX (additions to existing MSCZWriter)
extension MSCZWriter {
    /// Serialize a `Score` to `.mscx` and package the result as `.mscz` bytes.
    public static func write(score: Score, mainFileName: String = "score.mscx") throws -> Data

    /// Serialize a `Score` to `.mscx` and write the resulting `.mscz` to a file URL.
    public static func write(score: Score, to url: URL, mainFileName: String = "score.mscx") throws
}

// SheetMusic (façade additions)
extension SheetMusic {
    public static func exportMSCX(_ score: Score, to url: URL) throws
    public static func exportMSCZ(_ score: Score, to url: URL) throws
}
```

All entry points use `throws`; no `Result` types, no Optional return for
failure (CLAUDE.md convention). New error cases are not anticipated;
serialization failures map to `SheetMusicError.malformedScore` for
internal-state violations and existing `corruptedContainer` / `ioError`
for archive / disk failures.

## Testing

`Tests/SheetMusicTests/MSCXRoundTripTests.swift` (new file):

```swift
@Test("midi01 round-trip preserves Score equality")
func midi01RoundTrip() throws {
    let originalData = try fixture("midi01.mscx")
    let original = try MSCXParser.parse(originalData)

    let encoded = try MSCXEncoder.encode(original)
    let roundTripped = try MSCXParser.parse(encoded)

    #expect(original == roundTripped)
}

@Test("midi01 round-trips through MSCZ")
func midi01MSCZRoundTrip() throws {
    let originalData = try fixture("midi01.mscx")
    let original = try MSCXParser.parse(originalData)

    let mscz = try MSCZWriter.write(score: original)
    let roundTripped = try MSCZReader.read(mscz)

    #expect(original == roundTripped)
}
```

Plus low-level unit tests for `XMLTreeSerializer` (escaping, empty-element
self-closing, attribute ordering stability) so encoder bugs and
serializer bugs are diagnosable independently.

The `MidiExportTests` suite is untouched.

## Phased extension (out of this spec)

After Phase 1 is in:

- **Phase 2:** add encoders for elements present in the other test
  fixtures — Spanner / KeySignature mid-piece changes / MeasureRepeat
  / Arpeggio / Glissando / Harmony / Dynamic / Tempo changes.
  Each is a separate spec scoped to one fixture or feature group.
- **Phase 3:** validate that hand-built `Score` values (not parsed from
  any `.mscx`) produce MuseScore-Studio-openable output. This requires
  decisions about default `<Style>` values, default eid generation,
  and `<Instrument>` filling — large enough to deserve its own spec.

## Implementation worktree

Already created:

```
git worktree add .worktrees/mscx-export -b feature/mscx-export main
```
