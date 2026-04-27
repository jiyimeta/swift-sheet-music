# Rehearsal Marks — Design

Date: 2026-04-27
Status: Approved (D-scope: Core + MSCX + MusicXML + MIDI + UI/PDF)

## Goal

Implement rehearsal marks (e.g. "A", "B", "1サビ") end-to-end:

1. Parse them from MuseScore `.mscx`.
2. Import them from MusicXML.
3. Carry them through the score model.
4. Emit them as SMF `Marker` meta-events on MIDI export.
5. Render them in the SheetMusicUI / PDF pipeline.

The `test.mscx` fixture in `Example/` already contains rehearsal marks
("1A", "1B", "1サビ", …) which the current pipeline silently drops; the
end state is that those appear correctly in the example app.

## Reference (MuseScore)

`engraving/dom/rehearsalmark.{h,cpp}`. `RehearsalMark` derives from
`TextBase` with a runtime-only `Type` enum (`Main` / `Additional`) that
controls applied style but is **not** serialized in MSCX. Read/write
delegates entirely to `TextBase`:

- `engraving/rw/read460/tread.cpp:932` — `read(RehearsalMark*) → read(TextBase*)`
- `engraving/rw/write/twrite.cpp:2711` — `write(RehearsalMark*) → writeProperties(TextBase, …, true)`
- `engraving/rw/read460/measureread.cpp:499` — recognised as a `<voice>` child

In `.mscx` it appears as a `<voice>` child:

```xml
<RehearsalMark>
  <text>A</text>
  <!-- optional, inherited from TextBase: -->
  <offset x="…" y="…"/>
  <color r="…" g="…" b="…" a="…"/>
  <frameType>0|1|2</frameType>     <!-- 0=square, 1=circle, 2=none -->
  <placement>above|below</placement>
</RehearsalMark>
```

In MusicXML 4 it appears as:

```xml
<direction placement="above">
  <direction-type>
    <rehearsal enclosure="square|circle|none" font-weight="bold">A</rehearsal>
  </direction-type>
</direction>
```

(See MuseScore's import code at
`importexport/musicxml/internal/import/importmusicxmlpass2.cpp` —
`m_rehearsalText` accumulator, `Factory::createRehearsalMark`.)

## Scope

### In scope

- `RehearsalMark` value type in `SheetMusicCore`
- `VoiceElement.rehearsalMark` case
- MSCX decoder (`<RehearsalMark>` inside `<voice>`)
- MusicXML import (`<direction-type><rehearsal>`)
- MIDI export — `MetaEvent.marker(String)` (SMF type `0xFF 0x06`)
  emitted on the conductor track at the rehearsal mark's tick
- UI/PDF rendering — `LayoutElement.rehearsalMark`, drawn boxed/circled
  above the top staff at the measure's left edge
- Unit tests + Example app visual check

### Out of scope (deferred)

- `Main` / `Additional` type distinction (not serialized in MSCX, can
  be reintroduced later if a user-style hook needs it)
- Round-trip writing — neither MSCZ Writer nor MusicXML export are
  full-coverage today; rehearsal marks are read-only for now
- Honouring custom font/size beyond the frame kind
- Mid-measure positioning (rehearsal marks are anchored at the start
  of the containing measure for layout purposes; the source-order
  position inside `<voice>` is preserved in the model but the renderer
  uses measure-left)

## Architecture

### Data model — `SheetMusicCore`

`Sources/SheetMusicCore/Score/RehearsalMark.swift`:

```swift
public struct RehearsalMark: Sendable, Equatable {
    public enum FrameKind: String, Sendable {
        case rectangle   // MuseScore frameType=0 / MusicXML enclosure="square"
        case circle      // frameType=1 / enclosure="circle"
        case none        // frameType=2 / enclosure="none"
    }

    public var text: String
    public var offsetX: Double
    public var offsetY: Double
    public var color: ScoreColor?
    public var frame: FrameKind

    public init(
        text: String,
        offsetX: Double = 0,
        offsetY: Double = 0,
        color: ScoreColor? = nil,
        frame: FrameKind = .rectangle
    )
}
```

The default `frame = .rectangle` matches MuseScore's
`Sid::rehearsalMarkFrameType` default for the Main rehearsal style.

`VoiceElement` gains:

```swift
case rehearsalMark(RehearsalMark)
```

### MSCX decoder — `SheetMusicMSCX`

New file `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+RehearsalMark.swift`
mirroring `MSCXDecoder+StaffText.swift`:

- Read `<text>` (recursive plain-text walk for inline `<font>` etc.)
- Read `<color>` (RGBA attributes)
- Read `<offset>` (x/y attributes, spatium units)
- Read `<frameType>` numeric value → `FrameKind` (default `.rectangle`)
- Unknown children silently ignored (decoder-permissive convention)

`MSCXDecoder+Voice.swift` gains:

```swift
case "RehearsalMark":
    elements.append(.rehearsalMark(try RehearsalMark.decode(child)))
```

The colour/offset helpers in `MSCXDecoder+StaffText.swift` are currently
private. We keep both decoders self-contained in this first pass; if a
third consumer arrives, factor into a shared helper.

### MusicXML import — `SheetMusicMusicXML`

`MusicXMLDecoder+Jump.swift` already extracts navigation markers from
`<direction>`. We add a sibling concern for rehearsal marks:

`MusicXMLDecoder+RehearsalMark.swift`:

- Walk `<direction-type><rehearsal>` children
- Map `enclosure` attribute: `square|none` → matching `FrameKind`,
  `circle` → `.circle`, missing → `.rectangle` (MuseScore default)
- Capture `default-x`/`default-y` if present (kept as 0,0 for now —
  MusicXML positions are tenths, so `MusicXMLContainer` would need to
  convert; out of scope, mirroring how `StaffText`/`Jump` handle it)

`StaffMeasureBuilder` gains `addRehearsalMark(_:)`. `MusicXMLDecoder+Measure.swift`
attaches the parsed mark to staff-0's first voice as a `VoiceElement.rehearsalMark`.
(Single rehearsal mark per direction, single attachment point — matches
MuseScore's MusicXML import behaviour where it ends up on the
top-staff segment at that tick.)

### MIDI export — `SheetMusicMIDI`

`MetaEvent` gets a new case:

```swift
case marker(String)
```

`MidiWriter.encodeMeta` adds:

```swift
case .marker(let text):
    encoder.appendUInt8(0x06)
    let bytes = Data(text.utf8)
    encoder.append(VariableLengthQuantity.encode(bytes.count))
    encoder.append(bytes)
```

In `MidiRenderer+Voice.swift`, when a `VoiceElement.rehearsalMark` is
encountered, append a `TimedMidiEvent(.meta(.marker(text)))` to the
conductor track at the current tick. Conductor track = track 0
(the one that already carries time/key signature meta-events). Other
voices' rehearsal marks are NOT duplicated — the renderer takes them
from the first staff's first voice only, matching the system-flag
convention. (If multiple voices on the first staff carry distinct
rehearsal marks at the same tick, we keep the first; this matches
MuseScore's behaviour of de-duplicating system-flagged elements.)

### UI/PDF rendering — `SheetMusicUI`

`LayoutElement` gains:

```swift
case rehearsalMark(
    text: String,
    origin: CGPoint,
    frame: RehearsalMark.FrameKind,
    color: ScoreColor?
)
```

Layout placement (in `LayoutEngine.swift`, near the existing marker
emitter at the per-system-block staff loop):

- Iterate staff-0's measure looking at every `VoiceElement.rehearsalMark`
  (across all voices, but de-duplicate by text — typical sources only
  put one per measure, and the linked-main second voice in test.mscx
  duplicates the same text).
- Place at `(0, staffTopY - sp * 1.5)` — same y-band as marker/measure
  number, with x at the measure's left edge. This matches MuseScore's
  default layout for rehearsal marks.
- Apply the source `offsetX` / `offsetY` (spatium units) on top of the
  default placement.

Rendering (`ScoreLayerBuilder.swift`, new `drawRehearsalMark`):

- Bold text at `metrics.sp * 2.5` (matches Marker text style)
- Frame:
  - `.rectangle` — stroke a tight rectangle around the text bbox
    with a small inner padding (`sp * 0.4` per side)
  - `.circle` — stroke a circle whose diameter = max(text width,
    text height) + padding
  - `.none` — no frame
- Honour `color` if set, else default text colour

The PDF pipeline reuses `ScoreLayerBuilder` and inherits this for free.

## Data flow

```
.mscx  → MSCXDecoder+Voice → VoiceElement.rehearsalMark(RehearsalMark)
.musicxml → MusicXMLDecoder+RehearsalMark → StaffMeasureBuilder → Voice
                ↓
        Score (Measure → Voice → VoiceElement)
                ↓
   ┌────────────┼─────────────┐
   ↓            ↓             ↓
MidiRenderer  LayoutEngine   (PDF inherits via LayoutEngine)
   ↓            ↓
.meta(.marker)  LayoutElement.rehearsalMark
   ↓            ↓
SMF bytes      ScoreLayerBuilder.drawRehearsalMark
```

## Error handling

- Missing `<text>` / empty rehearsal element: decode succeeds with
  `text = ""`. The renderer will draw an empty box; we do not throw
  for this since MuseScore itself silently writes empty marks during
  authoring.
- Invalid `<frameType>` value: fall back to `.rectangle`.
- All paths follow the existing convention: throw
  `SheetMusicError.malformedScore` only when the structure is so
  broken we cannot continue (none of the rehearsal-mark fields qualify).

## Testing

1. **Core/MSCX parse** — new fixture
   `Tests/SheetMusicTests/Resources/rehearsal-mark.mscx`: a 2-measure
   piece with two rehearsal marks ("A" rectangle, "B" circle). Assert
   the resulting `Score` exposes `VoiceElement.rehearsalMark` with the
   expected text and frame kind.
2. **MIDI export** — same fixture: render through `MidiRenderer`,
   write via `MidiWriter`, reparse, assert track 0 contains
   `MetaEvent.marker("A")` at tick 0 and `MetaEvent.marker("B")` at
   the start of measure 2.
3. **MusicXML import** — inline-string XML with a `<direction-type>
   <rehearsal enclosure="circle">A</rehearsal></direction-type>`
   element. Assert the decoded score has a rehearsal mark with
   `frame == .circle` on staff-0 voice-0.
4. **Layout** — LayoutEngine test: feed a 1-measure score with a
   rehearsal mark, assert the resulting `LayoutElement` array contains
   `.rehearsalMark` at `x ≈ 0`, `y ≈ staffTopY - sp * 1.5`.
5. **Visual (manual)** — run the Example app on
   `Example/SheetMusicExample/test.mscx` and confirm "1A", "1B",
   "1サビ" appear above the top staff.

The MIDI semantic-comparison harness
(`MidiSemanticComparison.swift`) does not currently emit marker
meta-events from MuseScore's reference SMFs, so the existing 12
`MidiExportTests` cases stay unchanged. New marker-specific assertions
go in a new dedicated test suite.

## File touch list

New files:

- `Sources/SheetMusicCore/Score/RehearsalMark.swift`
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+RehearsalMark.swift`
- `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+RehearsalMark.swift`
- `Sources/SheetMusicUI/Rendering/RehearsalMarkRenderer.swift` (or
  inline in `ScoreLayerBuilder.swift` — pick the consistent pattern
  with `MarkerRenderer.swift`)
- `Tests/SheetMusicTests/Resources/rehearsal-mark.mscx`
- `Tests/SheetMusicTests/RehearsalMarkTests.swift`

Edited files:

- `Sources/SheetMusicCore/Score/VoiceElement.swift` (add case)
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift` (dispatch)
- `Sources/SheetMusicMusicXML/Decoders/StaffMeasureBuilder.swift`
  (add `addRehearsalMark`)
- `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Measure.swift`
  (wire in)
- `Sources/SheetMusicMIDI/Model/MetaEvent.swift` (add case)
- `Sources/SheetMusicMIDI/IO/MidiWriter.swift` (encode)
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` (emit)
- `Sources/SheetMusicUI/Layout/LayoutElement.swift` (add case)
- `Sources/SheetMusicUI/Layout/LayoutEngine.swift` (place)
- `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder.swift` (draw)

Plus exhaustive switches everywhere `VoiceElement` and `MetaEvent`
are matched (renderers, layout passes, etc.) — pick up via build
errors after adding the new cases.
