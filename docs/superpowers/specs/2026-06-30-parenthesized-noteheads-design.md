# Parenthesized noteheads — design

**Date:** 2026-06-30
**Status:** Approved (design); implementation plan to follow.
**Scope chosen by user:** full fidelity ("C"). Parse **all three** MuseScore
serialization representations (rep1/rep2/rep3) on MSCX import, plus MusicXML
`<notehead parentheses="yes">`; round-trip on MSCX export; model the full
directional mode (`none`/`left`/`right`/`both`); render in **all three**
renderers (CALayer, SwiftUI Canvas, Android bridge).

## Problem

MuseScore can wrap a note's notehead in round parentheses — `(♪)` — for
editorial / cautionary / "ghost" notes (Note Properties → Parentheses). This
package has **no support for it anywhere**: not in the `Score` model, neither
parser, the layout engine, nor any of the three renderers. A parenthesized
note imports as a plain note and the parentheses are silently lost.

The closest existing feature is the recently-shipped **accidental
parenthesis / bracket** enclosure, which is implemented end-to-end across the
exact same layers. Notehead parentheses are structurally analogous (an
enclosure drawn around a glyph, orthogonal to the glyph's shape) and the SMuFL
glyphs are already present in the codepoint tables but unused.

The motivating real file is `~/Downloads/ロビンソン.mscz` (MuseScore 4.6.5,
`mscVersion 460`), which contains six parenthesized notes in the
representation-2 form (see below). It is a copyrighted song and must **not**
be committed; it is used only for local visual verification.

## Goals

1. Model a note's parenthesis state as a typed value on `Note`, carried
   through layout to the renderers.
2. Import parenthesized noteheads from MSCX/MSCZ across **all three** upstream
   representations:
   - **rep1** (MuseScore 1.x–4.5): `<Symbol><name>noteheadParenthesisLeft</name></Symbol>`
     (and `…Right`) as children of `<Note>`.
   - **rep2** (MuseScore 4.6, `mscVersion 460` — the real fixture):
     `<parentheses>both</parentheses>` property on `<Note>`, plus generic
     `<Parenthesis>` child elements.
   - **rep3** (MuseScore 4.7+, `mscVersion 470`): `<NoteParenGroup>` under
     `<Chord>`, binding parens to notes by `<NoteIdx>`.
3. Import parenthesized noteheads from MusicXML via `<notehead parentheses="yes">`.
4. Round-trip on MSCX **export**: re-emit the parenthesis state losslessly.
5. Render the left/right parenthesis SMuFL glyphs around the notehead in
   **all three** renderers, respecting the directional mode and small/cue
   magnification.
6. Cover all of the above with tests; verify visually against the real file.

## Non-goals

- **Bracket (square) enclosure around a notehead.** SMuFL has no notehead
  bracket glyph and MuseScore only offers round parentheses for noteheads; the
  square-bracket enclosure exists for *accidentals* only. Not modeled here.
- **One paren pair spanning several noteheads of a chord with a single tall
  parenthesis.** MuseScore's rep3 `<NoteParenGroup>` can enclose a *subset* of
  a chord's notes inside one vertically-stretched pair. We model parentheses
  **per note** (each enclosed note gets its own mode), so multiple enclosed
  notes render as individual paren pairs rather than one spanning pair. This is
  rare; documented as a known limitation, not a goal.
- **Playback / MIDI semantics.** Parentheses are display-only; MIDI is
  unchanged (pitch/duration/`play` are untouched).
- **Auto-suppression / cautionary logic.** Unlike redundant accidentals,
  parentheses are explicit user data and are never auto-hidden.

## Source-of-truth (studied from MuseScore, re-expressed)

Upstream MuseScore C++ (GPL-3.0, local clone `~/Developer/musescore/MuseScore`,
`MSC_VERSION 470`) is a behavioural spec only — no code copied. SMuFL codepoint
values are facts from SMuFL data.

Internal model facts (cited for provenance comments):
- `ParenthesesMode { NONE=0, LEFT=1, RIGHT=2, BOTH=3 }` — `types/types.h:768`.
- For **notes**, MuseScore only ever sets `BOTH` or `NONE`
  (`note.cpp:3964-3982`); `left`/`right` arise only from the generic
  `<Parenthesis>`/`<horizontalDirection>` plumbing. We still model all four
  for fidelity and to render a single side if a file ever encodes one.
- SMuFL glyphs already in our tables (`SMuFLCodepoints+Noteheads.swift:178-180`,
  by-name at `…+ByName.swift:404-406`):
  - `noteheadParenthesisLeft` = `0xE0F5`
  - `noteheadParenthesisRight` = `0xE0F6`
  - (`noteheadParenthesis` = `0xE0CE`, single enclosing glyph — unused here.)

### The three MSCX representations

**rep1 — `<Symbol>` children of `<Note>` (≤ 4.5).** Tag is `<name>`, not `<sym>`:

```xml
<Note>
  <Symbol><name>noteheadParenthesisLeft</name></Symbol>
  <Symbol><name>noteheadParenthesisRight</name></Symbol>
  …
</Note>
```

**rep2 — `<parentheses>` property + `<Parenthesis>` children of `<Note>` (4.6).**
This is the real fixture's form:

```xml
<Note>
  <parentheses>both</parentheses>
  <Parenthesis><eid>…</eid><track>16</track></Parenthesis>
  <Parenthesis><horizontalDirection>right</horizontalDirection><eid>…</eid><track>16</track></Parenthesis>
  <pitch>45</pitch><tpc>17</tpc>
</Note>
```
`<parentheses>` ∈ {`none`,`left`,`right`,`both`}. The `<Parenthesis>` children
carry `<horizontalDirection>` ∈ {`auto`,`left`,`right`} (default `left` if
absent) and assorted item props (`eid`/`track`/`offset`/`color`/`visible`).

**rep3 — `<NoteParenGroup>` under `<Chord>` (4.7+).**

```xml
<Chord>
  <Note>…</Note>
  <Note>…</Note>
  <NoteParenGroup>
    <Parenthesis><horizontalDirection>left</horizontalDirection></Parenthesis>
    <Parenthesis><horizontalDirection>right</horizontalDirection></Parenthesis>
    <Notes><NoteIdx>0</NoteIdx><NoteIdx>1</NoteIdx></Notes>
  </NoteParenGroup>
</Chord>
```
A `<Parenthesis>` is only written when user-modified, so a `<NoteParenGroup>`
may have only `<Notes>` and no `<Parenthesis>` children (defaults to both).
`<NoteIdx>` is the 0-based index into the chord's note list.

## Design

### 1. Model (`SheetMusicCore`)

New file `Sources/SheetMusicCore/Score/NoteParentheses.swift`:

```swift
/// Round-parenthesis enclosure around a notehead.
/// C++: mu::engraving::ParenthesesMode
public enum NoteParentheses: Sendable {
    case none
    case left
    case right
    case both
}
```

- Not `Int`-backed: MuseScore serializes these as strings, so the enum carries
  a `String` ↔ case mapping (init-from-token + token property) used by both the
  MSCX decoder/encoder and the MusicXML decoder.
- Convenience: `hasLeft`/`hasRight` computed bools for the renderers.

Add to `Note` (`Sources/SheetMusicCore/Score/Note.swift`), placed alongside the
existing `accidentalBracket` field:
- stored `public var parentheses: NoteParentheses` (default `.none`),
- a **defaulted** init parameter (`parentheses: NoteParentheses = .none`) so the
  many existing `Note(...)` call sites keep compiling unchanged.

### 2. MSCX import (`SheetMusicMSCX`)

`Decoders/MSCXDecoder+Note.swift`:
- **rep2:** read the Note's direct child `<parentheses>` → `NoteParentheses`.
  `<Parenthesis>` children are tolerated (their positioning is regenerated by
  layout; we do not need to read them for the mode). If `<parentheses>` is
  absent but a `<Parenthesis>` child exists, treat as `.both` (defensive).
- **rep1:** while iterating the Note's children, detect `<Symbol>` whose
  `<name>` text is `noteheadParenthesisLeft` / `noteheadParenthesisRight`; set
  the corresponding side (both present → `.both`). These symbols are then not
  re-emitted as generic symbols.

`Decoders/MSCXDecoder+Chord.swift`:
- **rep3:** after the notes are decoded, read a `<NoteParenGroup>` child of
  `<Chord>`. Resolve `<Notes><NoteIdx>n</NoteIdx>` to chord note indices and set
  each referenced note's `parentheses` from the group's `<Parenthesis>`
  `<horizontalDirection>` values (left + right present, or none specified →
  `.both`). Out-of-range indices are skipped defensively (permissive-parser
  policy — no throw).

All three are *cosmetic/embellishment* per the project's three-way policy:
unknown/garbled values default to `.none` silently (no diagnostic, no throw).

### 3. MusicXML import (`SheetMusicMusicXML`)

`Decoders/MusicXMLDecoder+Note.swift`: the `<notehead>` element is currently
never read. Add minimal handling: read its `parentheses` attribute; `="yes"` →
`.both`, otherwise `.none`. (The notehead *shape* text content remains out of
scope — only the `parentheses` attribute is consumed here.)

### 4. MSCX export round-trip (`SheetMusicMSCX`)

`Encoders/MSCXEncoder+Note.swift`: emit the representation matching the
encoder's existing target `mscVersion` (verify during planning; expected rep2 /
note-level for the current 4.x target):
- `<parentheses>both</parentheses>` (omitted when `.none`), plus the two
  `<Parenthesis>` children (left default; right with
  `<horizontalDirection>right`). For `.left`/`.right`, emit only the matching
  side. If the encoder targets 4.7+, emit rep3 (`<NoteParenGroup>` on the
  chord) instead — decided at plan time from the encoder's declared version.

Round-trip test asserts decode→encode→decode preserves the mode.

### 5. Layout carry-through (`SheetMusicLayout`)

`Layout/LayoutElement.swift`: add `public let parentheses: NoteParentheses` to
`LayoutChordNote` (next to `accidentalBracket`), with init param. Copy
`Note.parentheses` into it at the same seven sites that already copy
`accidentalBracket`:
- `LayoutEngine+Placement.swift` (×3), `LayoutEngine+Translate.swift` (×2),
  `ScoreCanvas.swift`, `ScoreLayerBuilder+Chord.swift`.

### 6. Glyph selection + placement (`SheetMusicLayout`, shared by all renderers)

Glyph helper (mirrors `AccidentalGlyph.enclosure`), e.g. in a new
`Engraving/NoteheadParenthesisGlyph.swift`:
```swift
// (left, right) SMuFL codepoints; nil when that side is absent.
static func glyphs(for mode: NoteParentheses) -> (left: UInt32?, right: UInt32?)
// .both → (0xE0F5, 0xE0F6); .left → (0xE0F5, nil); .right → (nil, 0xE0F6); .none → (nil, nil)
```

Placement helper (mirrors `AccidentalPlacement`), e.g.
`Engraving/NoteheadParenthesisPlacement.swift`:
- Notehead horizontal half-extent from `StemGeometry.attachDx(sp:)`; notehead
  edges = `origin.x ± attachDx`.
- Left paren sits a small `gapSp` to the left of the left edge; right paren a
  `gapSp` to the right of the right edge. Paren advance widths come from
  `FontMetrics.provider.typographicWidth`. Return center-anchor X for each side
  (the renderers draw center-anchored glyphs, as they do for accidental
  brackets).
- Vertical: center-anchored at `origin.y` (notehead center), same as the head.
- Magnification: scale the paren font size with the note's small/cue factor,
  identical to how the head glyph is sized.
- `gapSp` constant tuned against the real fixture during visual verification.

### 7. Rendering (three renderers)

In each per-note loop, immediately after the head glyph is drawn, draw the
left/right paren glyphs at the placement helper's positions, mirroring the
accidental-bracket draw calls:
- **CALayer (active):** `ScoreLayerBuilder+Chord.swift` `drawChord` → `glyphLayer`.
- **SwiftUI Canvas:** `ScoreCanvas.swift` chord case (+ a `NoteheadRenderer`
  helper) → `GraphicsContext.drawGlyph`.
- **Android bridge:** `LayoutBridge+Chord.swift` `emitNoteGlyphs` →
  `emitCenterAnchoredGlyph`.

Parentheses wrap the **notehead only** (not stem, flag, beam, or ledger lines).

### 8. Tests (`SheetMusicTests`, Swift Testing)

- **MSCX parse:** hand-authored minimal `.mscx` strings for rep1, rep2, rep3 →
  assert the target note's `parentheses == .both` (and a left-only / right-only
  case for rep3). Synthetic XML — no copyrighted/GPL fixture committed.
- **MusicXML parse:** minimal `<note>` with `<notehead parentheses="yes">` →
  `.both`; absence → `.none`.
- **Round-trip:** decode → encode → decode preserves mode.
- **Layout carry:** `LayoutChordNote.parentheses` equals the source note's.
- **Draw:** Android `LayoutBridge` draw-command test asserts the two paren
  glyph codepoints (`0xE0F5`/`0xE0F6`) are emitted at the expected left/right
  positions for a `.both` note and absent for `.none` (deterministic; no font
  dependency).
- New test files importing Apple frameworks/sub-libraries are wrapped in
  `#if !os(Android)`; run `Scripts/gate-android-tests.sh` after adding files.

### 9. Visual verification

Render the real `~/Downloads/ロビンソン.mscz` locally (SheetMusicExampleMac
and/or a `RenderPreviews` `#Preview`), confirm the six parenthesized notes draw
correct round parentheses hugging the notehead, and tune `gapSp`. The file is
**not** committed (copyrighted).

### 10. Merge gate

`swift test` 100% green, `Scripts/preflight.sh` (at minimum `--apple`), and
`swiftlint --quiet Sources Tests` at 0 warnings. Re-run `swift package describe`
with and without `SWIFT_SHEET_MUSIC_ANDROID` only if `Package.swift` changes
(none expected).

## Risks / open questions (resolve at plan time)

- **Encoder target version** for §4 (rep2 vs rep3) — read from the encoder's
  declared `mscVersion`.
- **`gapSp` value** — tune visually; start from the accidental-bracket gap
  (`0.16 sp`) and adjust.
- **Paren glyph vertical anchor** — confirm `0xE0F5/0xE0F6` center on the
  notehead the same way the head glyph anchors (SMuFL designs them to align);
  adjust the anchor if the visual check shows drift.
