# Articulation Glyph Rendering — Design

Date: 2026-05-08

## Summary

Render staccato dot, staccatissimo wedge, and tenuto bar on the staff
through the project's own layout / UI / PDF pipeline. Builds on
`feature/note-articulations`, which shipped the model
(`Chord.articulations`), MSCX round-trip, and MIDI gateTime shortening
but explicitly deferred glyph rendering.

The model and round-trip are already in place. The MIDI renderer
already shortens note durations. Native MuseScore renders the glyphs
when opening our exported `.mscx`. This PR closes the loop so the
project's own renderer (used by `SheetMusicUI` and `SheetMusicPDF`)
shows the same glyphs.

## Motivation

- **Visual fidelity:** Without glyphs the staccato is silent on the
  page even though it shortens playback. The score view, the PDF
  export, and the example app all under-report the source.
- **Consistency:** Round-trip is already exact at the bytes level;
  visual equivalence with MuseScore should match.
- **Cheap addition:** The hooks (LayoutElement enum, fermata-style
  renderer, ScoreCanvas / ScoreLayerBuilder switches) already exist.

## Non-goals

- Editor APIs to add or remove articulations on a `Chord`. Read +
  display only — same boundary as the model PR.
- Velocity-shaping articulations (accent / marcato / sforzato). Same
  scope boundary as the round-trip PR.
- Ornaments (trill / mordent / turn), ChordLine, Bend, Vibrato.
- Articulation glyphs on `GraceChord`. The model has no
  `articulations` field on graces.
- Articulation collisions across voices on the same staff. Real scores
  almost never produce this; revisit if needed.
- Layout side-effects: articulation glyphs do not change beam slope,
  slur shape, or system spacing horizontally. They only contribute to
  the staff's vertical bounds (so a stack of articulations doesn't
  collide with a system above or below).

## Reference points (MuseScore C++)

- `engraving/dom/articulation.cpp` — `Articulation::layout()` for the
  per-chord placement rule (anchor + offset).
- `engraving/dom/chord.cpp` — `Chord::layoutArticulations` for the
  outside-staff push and per-chord stacking.
- SMuFL — `articStaccatoAbove` etc. codepoints (Bravura defines all
  six glyphs we need; see Mapping below).

## Architecture

The Layout layer emits a new `LayoutElement.articulation` for each
in-scope `ChordArticulation`. The Renderer layer adds a switch case
that draws a SMuFL glyph at that origin. PDF reuses the same code
path — no PDF-specific changes needed.

```
Chord.articulations
        │
        ▼
LayoutEngine+Placement   (anchor resolve, Y offset, stack)
        │
        ▼
LayoutElement.articulation(kind, origin, isAbove)
        │
        ├─► ScoreCanvas        ─► ArticulationRenderer.draw → drawGlyph
        └─► ScoreLayerBuilder  ─► CALayer entry per glyph
                  ▲
                  │ (also reused by PDFPageView / PDFPageLayerView)
```

## File-by-file diff summary

```
Sources/SheetMusicLayout/Layout/LayoutElement.swift
  + enum ArticulationKind (staccato / staccatissimo / tenuto)
  + case articulation(kind: ArticulationKind, origin: CGPoint, isAbove: Bool)

Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift
  + per-chord articulation emit block (anchor resolve, Y, stacking)

Sources/SheetMusicLayout/Layout/LayoutEngine+YBounds.swift
  + .articulation case extending vertical bounds

Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift
  + .articulation case for the y-shift translator

Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift
  + articStaccatoAbove/Below
  + articStaccatissimoAbove/Below
  + articTenutoAbove/Below
  (only the entries that aren't already defined)

Sources/SheetMusicUI/Rendering/ArticulationRenderer.swift           [NEW]

Sources/SheetMusicUI/Rendering/ScoreCanvas.swift
  + .articulation case → ArticulationRenderer.draw

Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift
  + .articulation case → glyph layer entry

Tests/SheetMusicTests/LayoutArticulationTests.swift                 [NEW]
```

## LayoutElement extension

Inside the existing `enum LayoutElement` body in
`LayoutElement.swift`, add the nested enum and the new case:

```swift
@available(macOS 15.0, iOS 16.0, *)
public enum LayoutElement: Sendable, Equatable {
    // ... existing cases ...

    case articulation(
        kind: ArticulationKind,
        origin: CGPoint,
        isAbove: Bool
    )

    public enum ArticulationKind: Sendable, Equatable {
        case staccato
        case staccatissimo
        case tenuto
    }
}
```

Both must be added inline to the enum body — Swift does not allow
adding new cases via `extension`. Place the case alongside the other
chord-attachment cases (near `.fermata`) and the nested enum at the
bottom near `TextMarkKind` / `SpannerKind`.

`ArticulationKind` is layout-local and intentionally smaller than
`ChordArticulation.Kind`: it has no `.unknown` case, because the
emitter filters those out before producing a `LayoutElement`. This
keeps the renderer's switch exhaustive without needing a default
clause.

## Emission (`LayoutEngine+Placement.swift`)

Right after appending the chord's `mainElement` to `out`, iterate
`chord.articulations`:

1. **Filter:** drop any `art.kind == .unknown(...)` entries before
   any further work. They round-trip via the model but never render.
2. **Anchor resolve:**
   - `art.anchor == .above` → above
   - `art.anchor == .below` → below
   - `art.anchor == nil`    → opposite of `stem` (Gould's
     "opposite-side rule": stem-up → below, stem-down → above)
3. **Y origin (per anchor side):**
   - above: `min(notes.map(\.origin.y)) - 0.5 * sp`
   - below: `max(notes.map(\.origin.y)) + 0.5 * sp`
4. **Outside-staff push:** if the resulting Y lies strictly inside
   the staff (between `staffTopY` and `staffBottomY`), shift it past
   the nearest staff edge by 0.5 sp:
   - above placement: clamp to `min(Y, staffTopY - 0.5 * sp)`
   - below placement: clamp to `max(Y, staffBottomY + 0.5 * sp)`
5. **Stacking:** when more than one articulation lands on the same
   side, accumulate +1 sp in the anchor direction per additional
   glyph (innermost first, in `Chord.articulations` source order).
6. **X origin:** chord's notehead column centre (`stemOrigin.x`,
   adjusted by mirror dx if the chord has mirrored heads — reuse
   the existing helper).

`staffTopY` / `staffBottomY` are derived from the chord-emit
context's `staffMidY` and `metrics.sp` — same coordinate system used
by fermata and tuplet placement:

```
staffTopY    = staffMidY - 2 * sp     // top staff line (5-line staff)
staffBottomY = staffMidY + 2 * sp     // bottom staff line
```

The `notes` array in the pseudocode below is the `chordNotes` local
already in scope at the chord-emit site (after `applyChordMirroring`
runs).

Pseudocode:

```swift
var aboveCount = 0
var belowCount = 0
for art in chord.articulations {
    guard let kind = renderableKind(art.kind) else { continue }
    let isAbove = resolveIsAbove(art.anchor, stem: stem)
    let baseY = isAbove
        ? (notes.map(\.origin.y).min() ?? so.y) - 0.5 * sp
        : (notes.map(\.origin.y).max() ?? so.y) + 0.5 * sp
    let pushed = pushOutsideStaff(baseY, isAbove: isAbove,
                                   staffTopY: ..., staffBottomY: ...,
                                   sp: sp)
    let stackOffset = sp * CGFloat(isAbove ? aboveCount : belowCount)
    let y = pushed + (isAbove ? -stackOffset : stackOffset)
    out.append(.articulation(
        kind: kind,
        origin: CGPoint(x: chordX, y: y),
        isAbove: isAbove
    ))
    if isAbove { aboveCount += 1 } else { belowCount += 1 }
}
```

`renderableKind(_:)` maps `ChordArticulation.Kind` → optional
`LayoutElement.ArticulationKind`, returning `nil` for `.unknown(...)`.

## YBounds extension

`LayoutEngine+YBounds.swift` already walks every `LayoutElement` to
compute the staff's vertical reach for system spacing. Add a case
that contributes `origin.y` (treating the glyph as a thin point — the
glyph height is small relative to staff line spacing). Same shape as
the existing `.fermata` case.

## Translate extension

`LayoutEngine+Translate.swift` shifts an element's origin by a delta
when packing systems. Mirror the `.fermata` case for `.articulation`.

## Renderer

New file `Sources/SheetMusicUI/Rendering/ArticulationRenderer.swift`:

```swift
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum ArticulationRenderer {
    static func draw(
        context: inout GraphicsContext,
        kind: LayoutElement.ArticulationKind,
        isAbove: Bool,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let glyph: SMuFLGlyph
        switch (kind, isAbove) {
        case (.staccato, true):       glyph = .articStaccatoAbove
        case (.staccato, false):      glyph = .articStaccatoBelow
        case (.staccatissimo, true):  glyph = .articStaccatissimoAbove
        case (.staccatissimo, false): glyph = .articStaccatissimoBelow
        case (.tenuto, true):         glyph = .articTenutoAbove
        case (.tenuto, false):        glyph = .articTenutoBelow
        }
        context.drawGlyph(glyph, at: origin, size: metrics.glyphFontSize)
    }
}
```

Wired into `ScoreCanvas.swift` and `ScoreLayerBuilder+Element.swift`
alongside the existing `.fermata` case. PDF picks this up
automatically because `PDFPageView` calls
`ScoreCanvasDrawing.drawSystem` and `PDFPageLayerView` calls
`ScoreLayerBuilder.buildSystem`.

## SMuFL glyph mapping

| `LayoutElement.ArticulationKind` | isAbove | SMuFL name | Codepoint |
|---|---|---|---|
| `.staccato`      | true  | `articStaccatoAbove`      | U+E4A2 |
| `.staccato`      | false | `articStaccatoBelow`      | U+E4A3 |
| `.staccatissimo` | true  | `articStaccatissimoAbove` | U+E4A6 |
| `.staccatissimo` | false | `articStaccatissimoBelow` | U+E4A7 |
| `.tenuto`        | true  | `articTenutoAbove`        | U+E4A4 |
| `.tenuto`        | false | `articTenutoBelow`        | U+E4A5 |

Add only the entries that aren't already defined in `SMuFLGlyph.swift`.

## Tests

New file `Tests/SheetMusicTests/LayoutArticulationTests.swift`. Build
small Scores programmatically (mirror existing
`MidiRendererGlissandoTests` / `LayoutCacheTests` patterns) and assert
on the `[LayoutElement]` produced by `LayoutEngine.layout(...)`:

1. **Explicit above:** quarter (pitch 60) with `.staccato/.above` →
   one `.articulation`, `isAbove == true`, Y = top notehead Y − 0.5 sp.
2. **Explicit below:** same chord with `.staccato/.below` → one
   `.articulation`, `isAbove == false`.
3. **Auto, stem-up:** quarter with `anchor: nil` on a stem-up chord →
   `isAbove == false` (opposite-side rule).
4. **Auto, stem-down:** quarter with `anchor: nil` on a stem-down
   chord → `isAbove == true`.
5. **Outside-staff push (above):** middle-line note (e.g. pitch 71 in
   treble) with `.staccato/.above` → Y past `staffTopY - 0.5 sp`,
   not between staff lines.
6. **Outside-staff push (below):** middle-line note with
   `.staccato/.below` → Y past `staffBottomY + 0.5 sp`.
7. **Stacking:** `[staccato/Above, tenuto/Above]` → two
   `.articulation` entries, second's Y exactly 1 sp further above.
8. **Unknown:** chord with only `.unknown(subtype: "articAccentAbove")`
   → zero `.articulation` entries (round-trip safe but not rendered).
9. **Kind mapping:** `.staccatissimo` and `.tenuto` produce the
   right `LayoutElement.ArticulationKind` cases.

Renderer-side tests piggy-back on existing
`ScoreLayerRenderTests` (or its sibling) — extend the parameterised
case list with one chord that includes a staccato to confirm:
- The `.articulation` LayoutElement routes through the
  `ScoreLayerBuilder` switch and produces a glyph layer entry.
- `ScoreCanvas` doesn't crash on the new case (smoke).

## Visual verification (out of CI)

User runs `SheetMusicExampleMac`, opens an mscx with chord-level
staccato (e.g. our existing `midi01.mscx` augmented with one
articulation programmatically, or any MuseScore export), and
visually confirms the dot appears in the right place. Per project
memory, visual verification uses the Mac example app — not the iOS
simulator.

## Risks / open questions

- **SMuFLGlyph entry availability:** the SMuFL list in
  `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift` may already
  contain some of the six glyphs (fermata neighbour entries hint
  that the file is grown lazily). The implementation plan should
  start by adding only missing entries to keep the diff small.
- **Auto anchor accuracy:** the "opposite-side rule" matches Gould's
  default; MuseScore additionally biases toward `Above` on isolated
  notes for visual clarity in some cases. The simple rule is good
  enough for v1 and produces stable round-trips.
- **Outside-staff edge case:** ledger-line notes (notes already past
  the staff edge) need no push — the formula naturally gives Y past
  the staff edge already. Tests #5/#6 are the load-bearing checks.
- **Existing `MSCXRoundTripTests` / golden tests:** none of these
  inspect `LayoutElement.articulation`, so no fixture changes
  required. Layout output for chords without articulations stays
  bit-identical.
