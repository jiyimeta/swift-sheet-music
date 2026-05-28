# Element Visibility — Design

**Date:** 2026-05-28
**Branch:** `feature/element-visibility`
**Status:** Design (awaiting review)

## Summary

MuseScore lets the user hide individual elements — notes, dynamics, tempo
text, rests, clefs, etc. — from the engraved/printed output while keeping
them in the score model and (crucially) in playback. This is the
`<visible>` property. `swift-sheet-music` already supports it on a handful
of types (Tempo, StaffText, Harmony, Swing, Spanner, BracketItem) but not
on the most common ones (notes, dynamics, rests, …) and the existing
support is implemented ad-hoc per type.

This work introduces a **shared element-property aggregate** so visibility
(and future base-element properties such as colour, offset, autoplace)
attach uniformly, adds a **`showsInvisibleElements` rendering toggle**
(MuseScore's "Show Invisible"), and extends visibility coverage across the
model in phases.

## Background — MuseScore behaviour (behavioural spec)

Studied from the MuseScore 4.x source (`src/engraving/…`), used only as a
behavioural reference (no code copied).

- **`visible` is a base-class property.** It lives on `EngravingItem`
  (the base of every engravable element) as `ElementFlag::INVISIBLE`
  (`visible() == !flag(INVISIBLE)`). Default is **visible (true)**.
- **XML form.** Tag `<visible>` with `0`/`1`. Omitted when `true` (the
  default); written only as `<visible>0</visible>` when hidden.
- **Playback is independent.** An invisible note **still sounds**. Whether
  a note sounds is governed by the separate `Note::play()` property
  (`<play>0</play>`), already modelled here as `Note.play`. The playback
  render path (`NoteRenderer::shouldRender`) checks `play()`, never
  `visible()`.
- **Layout / drawing.** In print/export, invisible elements are not drawn.
  In edit mode with "Show Invisible" on, they are drawn at
  `invisibleColor()` = `#808080` (50 % grey). Invisible elements do not
  contribute to the skyline (vertical collision avoidance), but a
  note/rest still occupies its **rhythmic slot** — hiding a note leaves a
  gap, it does not collapse the bar's spacing.
- **The base-element persisted property set is mostly non-visual and
  growing.** Of the ~12 properties written at the `EngravingItem` base
  level, only `offset` / `color` / `visible` / `z` are visual; the rest
  (`autoplace`, `minDistance`, `placement`, `track`, the three
  `*LinkedToMaster` / `excludeFromOtherParts` part-linking flags,
  `hasParentheses`) are behavioural/structural. This motivates a
  general "properties" aggregate rather than an "appearance"-only one.

## Current state of the codebase

- `Note` (`Sources/SheetMusicCore/Score/Note.swift`) has `play: Bool` but
  **no** visibility.
- Rests are **empty `Chord`s** (`VoiceElement.swift`: a `Chord` whose
  `notes` is empty). `Chord` has no visibility.
- `Dynamic`, `Fermata`, `RehearsalMark`, `Lyric`, `Clef`,
  `KeySignature`, `TimeSignature`, `BarLine`, `Arpeggio`: no visibility.
- Already have `var visible: Bool`: `Tempo`, `StaffText`, `Harmony`,
  `Swing`, `Spanner`, `BracketItem` — each implemented ad-hoc (own stored
  bool, own decode line `(node.first("visible")?.text ?? "1") != "0"`, own
  encode line `if !visible { children.append(…"visible", "0") }`).
- Layout already honours visibility by **skipping emission** with
  `if !visible { break }` (e.g. `LayoutEngine+Placement.swift` for tempo /
  staffText / swing / harmony; `LayoutEngine+Spanners.swift`;
  `LayoutEngine+SystemBuild.swift` for brackets).
- `LayoutElement` cases (`Sources/SheetMusicLayout/Layout/LayoutElement.swift`)
  carry no visibility marker.
- UI has **two renderers** (Canvas + CALayer / `ScoreLayerBuilder`) — both
  must honour any greying. `StickyHeaderView` already references
  MuseScore's `invisibleColor()` (#808080) via a 50 % opacity layer.
- MIDI render (`Sources/SheetMusicMIDI/Render/…`) gates note emission on
  `note.play` only — correct; must stay untouched by visibility.

## Design

### 1. Shared aggregate: `ElementProperties` (SheetMusicCore)

A struct (not an `OptionSet`) so it can grow with **value-typed**
properties (colour, offset) as well as flags — matching MuseScore's
base-element set, which is two-thirds non-visual and still growing.

```swift
/// Properties shared by all engravable elements — the subset of
/// MuseScore's base `EngravingItem` persisted state this library models.
/// Deliberately a struct (not an OptionSet): the upstream base set is
/// mostly non-visual (offset, autoplace, placement, part-linking, …) and
/// keeps growing, so value-typed fields must be addable here later.
/// C++: mu::engraving::EngravingItem base properties (subset).
public struct ElementProperties: Sendable, Equatable {
    /// Hidden from rendered/printed output. MuseScore
    /// `ElementFlag::INVISIBLE` / `<visible>0</visible>`. Default true.
    /// Playback (MIDI) is unaffected — sounding is governed elsewhere
    /// (e.g. `Note.play`).
    public var visible: Bool

    // Reserved extension points (NOT implemented in this work):
    //   public var color: ScoreColor?      // <color>
    //   public var offset: ...             // <offset>
    //   public var autoplace / placement   // behavioural
    // When boolean flags proliferate, the bool cluster may be backed by
    // an internal OptionSet behind these computed accessors without
    // changing call sites.

    public init(visible: Bool = true) { self.visible = visible }
    public static let `default` = ElementProperties()
}
```

**Naming decisions (settled):**
- Type: **`ElementProperties`** — "properties common to every element".
  Not `Appearance`/`VisualProperties` (would mislead/rename as non-visual
  fields are added). Not bare `Properties` (collision-prone).
- Stored field on each element: **`elementProperties`** — avoids clashing
  with the existing `properties: TextProperties` field on text elements.
- Render toggle: **`showsInvisibleElements`** — Swift Bool-property
  convention (third-person verb, cf. `UIScrollView.showsVerticalScrollIndicator`).

### 2. Per-element wiring

Each visibility-bearing element gains:

```swift
public var elementProperties: ElementProperties   // stored
public var visible: Bool {                         // ergonomic sugar
    get { elementProperties.visible }
    set { elementProperties.visible = newValue }
}
```

- Memberwise inits keep an ergonomic `visible: Bool = true` parameter
  (internally `self.elementProperties = ElementProperties(visible: visible)`),
  so existing call sites and tests are **unchanged**.
- The six existing ad-hoc types are **migrated** to this representation
  (stored `var visible: Bool` → `var elementProperties`, plus the `visible`
  sugar). Public API stays source-compatible.

### 3. Shared MSCX decode / encode helpers (SheetMusicMSCX)

One reader + one writer over the whole `ElementProperties` struct, so a
future field (e.g. `<color>`) is added in **two places** (the struct and
the helper) rather than in every decoder/encoder:

```swift
// Decode: reads <visible> (and future <color>, …) from an element node.
extension ElementProperties {
    init(decodingMSCXChildrenOf node: XMLNode) {
        self.init(visible: (node.first("visible")?.text ?? "1") != "0")
    }
}

// Encode: emits <visible>0</visible> only when hidden (and future tags).
extension ElementProperties {
    func mscxChildren() -> [XMLTreeNode] {
        var out: [XMLTreeNode] = []
        if !visible { out.append(XMLTreeNode(name: "visible", text: "0")) }
        return out
    }
}
```

Each element decoder calls `ElementProperties(decodingMSCXChildrenOf:)`;
each encoder appends `elementProperties.mscxChildren()`. Migrated types
drop their hand-rolled visible lines in favour of these.

### 4. Element coverage (phased)

The shared aggregate makes per-element cost small, so coverage is
comprehensive, delivered in phases. Each phase = add field → decode →
encode → round-trip test → honour in layout.

- **Phase 0 — Foundation.** `ElementProperties` + shared decode/encode
  helpers; migrate the six existing types; wire `showsInvisibleElements`
  through layout + both renderers (§5–6).
- **Phase 1 — Named elements.** `Note` (per-notehead), `Chord` (= rest),
  `Dynamic`.
- **Phase 2 — Structural.** `Clef`, `KeySignature`, `TimeSignature`,
  `BarLine`.
- **Phase 3 — Remaining.** `Fermata`, `RehearsalMark`, `Lyric`,
  `Arpeggio`.

Each phase is independently testable and mergeable.

### 5. MIDI invariant (no change)

Visibility never affects MIDI. Invisible notes/dynamics still emit
note-ons and drive velocity exactly as before; sounding remains governed
by `Note.play`. `MidiRenderer*` is **not modified**. A regression test
asserts that toggling `visible` on notes/dynamics produces byte-identical
SMF output.

### 6. Layout & the `showsInvisibleElements` toggle

- `LayoutEngine` gains an input option **`showsInvisibleElements: Bool`**,
  default **`false`** (print behaviour). Threaded via the existing layout
  options/metrics input, not global state.
- **`false`:** invisible elements are not emitted — preserving today's
  `if !visible { break }` pattern for annotations. For notes/rests,
  visibility suppresses only the **glyph**; the rhythmic slot, stem/beam
  geometry inputs, and horizontal spacing are unchanged (an invisible note
  leaves a gap, never collapses the bar). When **all** notes of a chord
  are invisible (or the chord/rest itself is), the stem/flag/beam glyphs
  are suppressed too (mirrors MuseScore's `allElementsInvisible`).
- **`true`:** invisible elements **are** emitted but tagged invisible so
  renderers grey them. The tag is carried at the **placed-element
  container level** (the per-system list of placed `LayoutElement`s), not
  by adding an associated value to every `LayoutElement` case — avoiding a
  churn across the whole enum and all renderer switches. Per-notehead
  greying within a partially-hidden chord uses the existing
  `LayoutChordNote` (which can carry an `isInvisible` flag) since notehead
  visibility is finer-grained than the element container.
- PDF export (`SheetMusicPDF`) always lays out with
  `showsInvisibleElements == false` (print behaviour).

### 7. Rendering — greying (both renderers)

When the container tags a placed element invisible, both the Canvas
renderer and the CALayer renderer (`ScoreLayerBuilder`) draw it in
`#808080` (50 % grey), matching MuseScore's `invisibleColor()`. Per the
dual-renderer parity rule this change must land in **both** paths or the
feature renders inconsistently.

### 8. Out of scope (documented future work)

- **MusicXML `print-object="no"`.** MusicXML's visibility attribute has
  subtly different semantics (per-object, attribute-based) and needs its
  own design; not addressed here.
- **Colour / offset / autoplace consolidation.** `ElementProperties` is
  designed to receive these, but migrating the existing colour handling
  (`TextProperties.color`, `ScoreColor?`) into it touches many text-element
  decoders and is a separate task.

## Testing strategy

- **Round-trip (MSCX):** for each covered element, parse a fixture with
  `<visible>0</visible>` → assert `visible == false` → re-encode → assert
  the `<visible>0</visible>` tag is present; and the inverse (true omits
  the tag). Extend to colour-bearing fixtures only when colour lands.
- **MIDI regression:** render a score, flip `visible` on its
  notes/dynamics, render again, assert identical SMF bytes.
- **Layout:** with `showsInvisibleElements == false`, assert hidden
  annotations are absent from the placed list and that an invisible note
  leaves the bar's spacing/positions identical to the visible case
  (slot preserved, glyph absent). With `true`, assert the element is
  present and tagged invisible.
- **Migration safety:** existing tests for the six already-`visible` types
  must pass unchanged (API compatibility check).

Tests use Swift Testing (`@Test` / `#expect`). Any test importing an
Apple-only sub-library (Layout/UI/PDF) or framework is wrapped in
`#if !os(Android)` and run through `Scripts/gate-android-tests.sh`.

## Risks / notes

- The migration of the six existing types changes their stored
  representation; the `visible` computed sugar keeps the public surface
  stable, but every internal `@testable` use and the decoders/encoders
  must be updated together (single mechanical sweep per type).
- Note-level vs chord-level visibility: a chord's stem/beam glyphs are
  derived in layout, so "hide the whole chord" is realised by suppressing
  noteheads + (when all hidden) the stem group, not by a separate stem
  model field.
