# MSCX Brackets & Per-Part Labels — Design

Date: 2026-05-04

## Summary

Read MuseScore's bracket / brace markup from `.mscx` files into the
Score model and render it. Replace the existing one-size-fits-all
"system bracket" with a typed list of brackets that mirror what
MuseScore serializes per `<Staff>`. As a related fix, collapse
duplicated per-staff part labels into one label per `Part` so that
multi-staff parts (piano grand staff) display the instrument name
once, vertically centered across the part's staves, instead of once
per staff.

Auto-derivation of brackets from instrument family / id (MuseScore's
`ScoreOrder::setBracketsAndBarlines`) is **out of scope** — that
logic is the consuming app's responsibility. This package handles
only what is explicitly serialized in MSCX.

## Motivation

Two bugs visible on the `multiPartMixedStaves` fixture (Vn1, Vn2,
Piano [2 staves], Cello):

1. The Piano "Piano" label is drawn twice — once per staff — instead
   of once vertically centered across the grand staff.
2. The existing `drawBracket` always emits one square bracket
   spanning every staff in the system regardless of part boundaries,
   which is incorrect for multi-part scores.

MuseScore's actual model is a list of `BracketItem`s on each `Staff`
(`<bracket type="..." span="..." col="..."/>`), with brace, thin
square, and thick normal as distinct types. The information is
already in any MSCX file written by MuseScore — we only need to
read it and draw it.

## Non-goals

- Auto-deriving brackets from instrument metadata
  (`Score::updateBracesAndBarlines`,
  `ScoreOrder::setBracketsAndBarlines`). Apps that need this can
  set `Staff.brackets` themselves before handing the `Score` to the
  layout engine.
- Bundling MuseScore's `instruments.xml` (GPL) or any derived
  family / section table.
- User-edit affordances for adding / removing brackets at runtime.

## Reference points (MuseScore C++)

- `engraving/dom/bracket.h` — `BracketType` enum (`NORMAL`, `BRACE`,
  `SQUARE`, `LINE`, `NO_BRACKET`).
- `engraving/dom/bracketItem.h` — `BracketItem` (type, span, column,
  visible).
- `engraving/dom/staff.h:90` — `Staff::addBracket` / `brackets()`.
- `engraving/rw/write/twrite.cpp:2847` — serialization to
  `<bracket type=… span=… col=… visible=…/>`.
- `engraving/rendering/score/tlayout.cpp:1396` — `BRACE` rendered via
  the SMuFL `brace` glyph stretched to staff range.

## Core model

New file `Sources/SheetMusicCore/Score/BracketItem.swift`:

```swift
/// Bracket / brace style. Mirrors MuseScore's
/// `engraving/dom/bracket.h` `BracketType` enum, including the same
/// raw integer values used in MSCX serialization.
public enum BracketType: Int, Sendable, Equatable, Codable {
    case normal     = 0   // thick angle bracket — section grouping
    case brace      = 1   // curly brace — multi-staff parts
    case square     = 2   // thin angle bracket — same-instrument grouping
    case line       = 3   // plain vertical line, no serifs
    case noBracket  = -1
}

/// One bracket / brace anchored on a `Staff`. The bracket spans
/// `span` staves downward starting from this staff (counting this
/// staff as 1). `column` controls horizontal nesting: 0 is the
/// outermost (closest to the staff), 1 sits one column further left,
/// etc. Multiple bracket items may share a staff.
///
/// C++: `mu::engraving::BracketItem`.
public struct BracketItem: Sendable, Equatable, Codable {
    public var type: BracketType
    public var span: Int
    public var column: Int
    public var visible: Bool

    public init(
        type: BracketType,
        span: Int,
        column: Int = 0,
        visible: Bool = true
    ) {
        self.type = type
        self.span = max(span, 1)
        self.column = max(column, 0)
        self.visible = visible
    }
}
```

`Sources/SheetMusicCore/Score/Staff.swift` — extend the existing
struct with one new property, default empty:

```swift
public var brackets: [BracketItem] = []
```

Place the property after the existing visual configuration fields
(staff type, default clef). Add a corresponding parameter (with
default `[]`) to the public initializer; existing callers compile
unchanged.

`Instrument` is **not** modified for this work.

## MSCX reader

Extend `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Staff.swift` so
that any `<bracket>` element directly under `<Staff>` becomes one
`BracketItem`:

```xml
<Staff id="1">
  ...
  <bracket type="1" span="2" col="0" visible="1"/>
</Staff>
```

Mapping rules:

- `type` (required): `Int(rawValue:)` on `BracketType`. Unknown
  values → silently drop the element (consistent with the parser's
  permissive policy for unknown content).
- `span` (required): `Int`. Values `< 1` are clamped to 1.
- `col` (optional, default 0): `Int`. Negatives clamped to 0.
- `visible` (optional, default 1): `"0"` → `false`, anything else →
  `true`.

Decode order: append to `Staff.brackets` in document order so column
ordering and stable diffing are preserved.

No changes to `Instrument` / `Part` decoding.

## Layout

### `LayoutSystem`

Add one new public field:

```swift
public let brackets: [LayoutBracket]
```

Defined alongside `LayoutPartLabel` in `LayoutSystem.swift`:

```swift
public struct LayoutBracket: Sendable, Equatable {
    public let type: BracketType
    public let topY: CGFloat       // top edge of the topmost spanned staff
    public let bottomY: CGFloat    // bottom edge of the bottommost spanned staff
    public let column: Int
}
```

The existing `partLabels: [LayoutPartLabel]` keeps its name but
changes semantics: one entry per `Part` (was one entry per staff).
See "Part labels" below.

### Part labels — per-Part collapse

Replace the existing per-staff label loop in
`LayoutEngine+SystemBuild.swift:400` with a per-Part loop:

```swift
let labels: [LayoutPartLabel] = score.parts.enumerated().map { partIdx, part in
    let text: String = isFirstSystem
        ? (part.instrument.longName ?? part.trackName ?? "")
        : (part.instrument.shortName
            ?? part.instrument.longName.map { String($0.prefix(3)) }
            ?? part.trackName.map { String($0.prefix(3)) }
            ?? "")
    // Resolve the part's flat staff range using StaffAddress.
    let firstFlat = allStaves.firstIndex { $0.address.partIndex == partIdx }!
    let lastFlat  = allStaves.lastIndex  { $0.address.partIndex == partIdx }!
    let topY    = staffOrigins[firstFlat].y
    let bottomY = staffOrigins[lastFlat].y + metrics.staffHeight
    let centerY = (topY + bottomY) / 2
    return LayoutPartLabel(
        text: text,
        origin: CGPoint(x: 4, y: centerY)
    )
}
```

Single-staff parts trivially keep their previous Y (centered on the
single staff). Multi-staff parts (Piano, Organ, Harp) get one label
at the midpoint between top of staff 0 and bottom of the last staff.

### Bracket geometry

Add a helper near `partLabelWidth`:

```swift
let bracketColumns = score.parts.flatMap { part in
    part.staves.flatMap { $0.brackets.map { $0.column } }
}
let bracketColumnCount = (bracketColumns.max() ?? -1) + 1
```

Extend `partLabelWidth`'s caller to leave space for `bracketColumnCount`
columns on the left of the staff. One column ≈ `sp * 1.5` of clearance
plus the bracket's own draw width.

In the same loop that emits `partLabels`, walk every `BracketItem` on
every `Staff` and emit one `LayoutBracket` per item:

```swift
var brackets: [LayoutBracket] = []
for (partIdx, part) in score.parts.enumerated() {
    let partFirstFlat = allStaves.firstIndex { $0.address.partIndex == partIdx }!
    for (staffIdxInPart, staff) in part.staves.enumerated() {
        let originFlat = partFirstFlat + staffIdxInPart
        for bi in staff.brackets where bi.visible && bi.type != .noBracket {
            let endFlat = min(
                originFlat + bi.span - 1,
                staffOrigins.count - 1
            )
            let topY    = staffOrigins[originFlat].y
            let bottomY = staffOrigins[endFlat].y + metrics.staffHeight
            brackets.append(LayoutBracket(
                type: bi.type,
                topY: topY,
                bottomY: bottomY,
                column: bi.column
            ))
        }
    }
}
```

A bracket whose `span` would extend past the last staff is clamped
silently (matches MuseScore's clamp in `BracketItem::staffIdx2`).

The new `brackets` array is threaded through every existing
`LayoutSystem.init` call site (carry-over from a `topShift` adjust,
`Ties` / `Spanners` rebuild paths). All sites currently rebuild a
system with the same brackets — no transformation of `topY` /
`bottomY` is needed beyond the same `+= topShift` already applied to
`staffOrigins` and `partLabels`.

## Rendering

### Replace `drawBracket` with `drawBrackets`

`Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Staves.swift`:

```swift
static func drawBrackets(
    system: LayoutSystem,
    metrics: StaffMetrics,
    height: CGFloat,
    into parent: CALayer
) {
    let staffOriginX = system.staffOrigins.first?.x ?? 0
    for b in system.brackets {
        let x = staffOriginX - bracketBaseInset(metrics)
            - CGFloat(b.column) * bracketColumnStride(metrics)
        switch b.type {
        case .brace:    drawBrace(   at: x, top: b.topY, bottom: b.bottomY, ...)
        case .normal:   drawNormal(  at: x, top: b.topY, bottom: b.bottomY, ...)
        case .square:   drawSquare(  at: x, top: b.topY, bottom: b.bottomY, ...)
        case .line:     drawLine(    at: x, top: b.topY, bottom: b.bottomY, ...)
        case .noBracket: continue
        }
    }
}
```

Geometric constants (sp = staff space):

| Type   | Spine width | Serif width | Serif length | Notes |
|--------|-------------|-------------|--------------|-------|
| normal | sp * 0.3    | sp * 0.25   | sp * 0.8     | Same as current `drawBracket`. |
| square | sp * 0.15   | sp * 0.15   | sp * 0.5     | Half-weight serif. |
| line   | sp * 0.15   | —           | —            | Spine only, no serifs. |
| brace  | SMuFL glyph (see below) | — | —     | Drawn via Bravura. |

Column stride: `sp * 1.0` per additional column (column 1 sits
`sp * 1.0` further left than column 0, etc.).
Base inset (column 0 X offset from staff): `sp * 0.5`.

### Brace glyph

Use Bravura's `brace` glyph (SMuFL `U+E000`). Bravura is already
registered at runtime (`SheetMusicLayout/Fonts/BravuraFont.swift`).
The glyph's native bounding-box height in the font is approximately
`8.55 sp` at the font's design size (Bravura's `staffSpace = 0.25 em`,
glyph height ≈ 2.14 em); compute the actual scale at runtime from
`CTFontGetBoundingRectsForGlyphs`. To stretch to the requested
`(topY, bottomY)`:

1. Resolve glyph index for `U+E000` via `CTFontGetGlyphsForCharacters`.
2. Call `CTFontGetBoundingRectsForGlyphs` to get the glyph's natural
   height `H_native` in points at the font's standard size.
3. Compute `targetHeight = bottomY - topY`.
4. Y-scale factor: `targetHeight / H_native`.
5. Draw the glyph in a `CATextLayer` (or `CGContext.showGlyphs` for
   PDF) with `CGAffineTransform(scaleX: 1.0, y: targetHeight / H_native)`
   applied around an anchor at `(x, topY)` so the glyph spans
   `[topY, bottomY]`.

X position: glyph's right edge sits `sp * 0.3` to the left of the
staff origin (the brace is closest to the staff, no other column is
inside it).

PDF renderer (`SheetMusicPDF`) uses the same metrics through
`CGContext` with `setTextMatrix` for the Y-scale.

## Tests

### New: `Tests/SheetMusicTests/BracketDecodingTests.swift`

- `decodeBraceWithSpanAndColumn` — `<bracket type="1" span="2" col="0"/>`
  → `BracketItem(.brace, span: 2, column: 0, visible: true)`.
- `decodeMultipleBracketsOnOneStaff` — staff with two `<bracket>`
  elements (col 0 and col 1) → two items in document order.
- `decodeOmitsCol` — `<bracket type="2" span="2"/>` → column 0.
- `decodeOmitsVisible` — defaults to `visible: true`.
- `decodeUnknownTypeIgnored` — `<bracket type="99" span="1"/>` →
  empty.
- `decodeNegativeSpanClampedToOne`.

### New: `Tests/SheetMusicTests/LayoutBracketTests.swift`

Uses an in-memory `Score` with hand-set `Staff.brackets` (no MSCX
round-trip required):

- `layoutBracketYFollowsStaffOrigins` — brace on Piano (2 staves)
  yields `topY = staffOrigins[2].y`,
  `bottomY = staffOrigins[3].y + staffHeight`.
- `layoutBracketColumnAffectsXPosition` — `column: 1` brackets are
  represented and the layout reserves left margin for `max column + 1`
  columns.
- `bracketSpanClampedAtScoreEnd` — bracket whose `span` exceeds
  remaining staves is clamped without crashing.
- `noBracketTypeNotEmitted` — `BracketType.noBracket` never appears
  in `LayoutSystem.brackets`.

### New: `Tests/SheetMusicTests/BracketRenderingTests.swift`

- `bracketLayersEmittedPerType` — given a `LayoutSystem` with one of
  each type, verify the layer tree contains a glyph (text) layer for
  brace and stroke layers for normal / square / line.

### Updated: `Tests/SheetMusicTests/LayoutPartLabelClefTests.swift`

The existing `partLabelsAndDefaultClefsAlignWithMultiStavePart` test
is rewritten:

- `partLabels.count == score.parts.count` (was `score.allStaves.count`).
- `partLabels[2].text == "Piano"` (the only Piano label).
- `partLabels[2].origin.y` falls within ±0.5 sp of the midpoint
  between staff 2's top and staff 3's bottom.

### Updated fixture: `Tests/SheetMusicTests/Resources/multiPartMixedStaves.mscx`

Add explicit `<bracket>` elements so the file matches what MuseScore
itself would write after `setBracketsAndBarlines`:

```xml
<Part id="1">
  <Staff id="1">
    <StaffType group="pitched"><name>stdNormal</name></StaffType>
    <defaultClef>G</defaultClef>
    <bracket type="0" span="2" col="0" visible="1"/>   <!-- NORMAL: Vn1+Vn2 -->
    <bracket type="2" span="2" col="1" visible="1"/>   <!-- SQUARE: Vn1+Vn2 -->
  </Staff>
  ...
</Part>
<Part id="3">
  <Staff id="3">
    ...
    <bracket type="1" span="2" col="0" visible="1"/>   <!-- BRACE: Piano staves -->
  </Staff>
  <Staff id="4">...</Staff>
  ...
</Part>
```

Update `MidiExportTests` and any other consumers of this fixture if
they assert on staff XML byte-equality.

### Updated init sites

`LayoutSystem.init` gains `brackets: [LayoutBracket]`. All call
sites pass through the value:

- `LayoutEngine+SystemBuild.swift` — primary producer.
- `LayoutEngine+Spanners.swift:180` — rebuild after spanner pass,
  pass `system.brackets` unchanged.
- `LayoutEngine+Ties.swift:231` — same.
- Test helpers (`PDFExporterTests`, `PDFExporterPageLayoutTests`)
  pass `brackets: []`.

## Migration / impact

- **Public API additions** (non-breaking):
  - `BracketType`, `BracketItem`, `LayoutBracket` types.
  - `Staff.brackets` (defaulted).
  - `LayoutSystem.brackets`.
  - `LayoutSystem.init` gains a parameter (defaulted to `[]`).
- **Public API behavior change**:
  - `LayoutSystem.partLabels.count` changes from "one per staff" to
    "one per part". External code that indexed `partLabels[i]` with
    a flat staff index will see different values. The new index
    aligns with `score.parts`. Fix any direct flat-index uses to go
    through `system.flatIndex(for: address)` → look up by part.
- **Renderer change**:
  - `ScoreLayerBuilder.drawBracket` is renamed to `drawBrackets` and
    consumes `system.brackets`. Callers in `SheetMusicUI` and
    `SheetMusicPDF` update accordingly.

No version bump beyond the next normal release; the package has not
yet hit 1.0 and breaking changes in `partLabels` semantics are
acceptable per existing convention.

## Out-of-scope follow-ups

- Auto-derivation pass (`Score.inferDefaultBrackets()`) that adds a
  brace to multi-staff parts lacking one and section / same-
  instrument brackets across parts. Belongs in the consuming app
  (or a future opt-in helper module) since it requires an
  instrument-id → family lookup.
- Editing UI for brackets.
- Custom bracket colors (MuseScore's `<bracket color="..." />`).
  Currently dropped on read.
