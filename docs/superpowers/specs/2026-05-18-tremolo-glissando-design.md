# Tremolo + MusicXML glissando + diatonic-glissando key signature — Design

Status: brainstormed 2026-05-18.

## Goal

Close three notation gaps surfaced during the post-articulations feature
audit:

1. **Tremolo** — Not modelled at all today. Implement single-note and
   two-note tremolo end-to-end (model → MSCX decode/encode → MIDI render
   → layout → UI draw).
2. **MusicXML `<glissando>` / `<slide>` import** — Glissando is fully
   wired for the MSCX path but absent from the MusicXML decoder.
3. **Diatonic glissando key-signature awareness** — Current MIDI
   renderer walks a hard-coded C-major pitch class set; correct it to
   use the active key signature's seven-tone pitch class set.

The three are bundled because they overlap thematically (single-note
articulations + glissando family) and share test-fixture infrastructure;
implementation can still be phased.

## Non-goals

- **Three-note or multi-note tremolo.** MuseScore supports only
  `r8|r16|r32` (single) and `c8|c16|c32` (two-note).
- **Z-stroke (buzz roll) MIDI semantics.** The model field exists, but
  MIDI rendering treats `.z` identically to `.traditional` for v1. TODO
  comment in renderer.
- **Tremolo through ties / spanners.** v1 renders each tremolo chord in
  isolation; existing tie/slur post-passes still apply to the resulting
  note-on list but no special handling.
- **MusicXML glissando export.** Repository has no MusicXML exporter
  today; nothing to extend.
- **MusicXML `line-type="dashed"` / `"dotted"`.** Mapped to `.straight`
  for v1. Extending `Glissando.VisualType` is a follow-up.
- **MuseScore-equivalent staff-line tracking for diatonic glissando.**
  Approximation via key-signature pitch class set is sufficient for
  v1; Tab clef and unusual staff geometries remain a known divergence.
- **Round-tripping legacy MS2/MS3 `<Tremolo>` payloads** beyond what
  MSCX subtype tokens already cover (no `<userMag>`, `<groups>`).

---

## Phase 1 — Tremolo

### Model

#### `Sources/SheetMusicCore/Score/Tremolo.swift` (new)

```swift
import Foundation

/// Beamed-stem tremolo notation. Attached to a `Chord`; for two-note
/// tremolo, the value is held by the *first* chord of the pair and the
/// second chord is named via `Span.between`.
///
/// C++: `mu::engraving::TremoloSingleChord` / `TremoloTwoChord`.
public struct Tremolo: Sendable, Hashable {

    /// Number of tremolo bars. Maps to MuseScore subtype tokens:
    /// `r8`/`c8` = 1 (eighth bar), `r16`/`c16` = 2, `r32`/`c32` = 3.
    public enum Subtype: UInt8, Sendable, Hashable {
        case r8 = 1
        case r16 = 2
        case r32 = 3
    }

    /// `.single`: bars cross the chord's own stem.
    /// `.between`: bars sit between this chord and the next chord in
    /// the same voice. The two chords have equal nominal duration and
    /// together fill the written value (MuseScore convention). The
    /// pair partner is *not* stored as a back-reference — it is looked
    /// up by walking the voice's element list, matching MuseScore's own
    /// approach and avoiding stale-ID hazards.
    public enum Span: Sendable, Hashable {
        case single
        case between
    }

    /// Stem-stroke variant. v1 MIDI rendering treats `.z` as
    /// `.traditional`. C++: `TremoloStyle`.
    public enum StrokeStyle: String, Sendable, Hashable {
        case `default`
        case traditional
        case z
    }

    public var subtype: Subtype
    public var span: Span
    public var strokeStyle: StrokeStyle

    public init(
        subtype: Subtype,
        span: Span = .single,
        strokeStyle: StrokeStyle = .default
    ) {
        self.subtype = subtype
        self.span = span
        self.strokeStyle = strokeStyle
    }
}
```

No new ID type is introduced. `NoteID` is note-level (see
`Sources/SheetMusicCore/Score/NoteID.swift`), and back-pointers to
sibling elements are intentionally avoided to keep the value-type model
free of cross-references (CLAUDE.md "No back-pointers; cross-references
live in rendering passes, not in the model"). Pair resolution happens
in the MSCX decoder's second pass, in the MIDI renderer's voice walk,
and in the layout pass — each operates on the live voice element list.

#### `Sources/SheetMusicCore/Score/Chord.swift`

Add:

```swift
public var tremolo: Tremolo?
```

with default `nil` in the initializer. Update `Hashable` /
`Equatable` if hand-written, plus the all-arguments init.

#### Error surface

`SheetMusicError.malformedScore` is thrown by the MSCX decoder when:

- `<Tremolo>` carries an unknown `<subtype>` token, or
- A `c8|c16|c32` tremolo has no following same-voice chord to pair
  with (i.e., the start chord is the last chord of its voice).

### MSCX decode

`Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift` learns to
consume the `<Tremolo>` child element:

```xml
<Chord>
  ...
  <Tremolo>
    <subtype>r16</subtype>
    <strokeStyle>1</strokeStyle>   <!-- 0=default, 1=traditional, 2=z -->
  </Tremolo>
  ...
</Chord>
```

- Parse subtype → `Tremolo.Subtype`; classify `r*` vs `c*` to fork into
  `.single` vs `.between` in the second pass.
- Optional `<strokeStyle>` (numeric token) → `StrokeStyle`. Absent →
  `.default`.
- Two-note pairing happens in a *second pass* after all voice chords
  are decoded: walk each voice in order, and for every chord carrying a
  `c*` tremolo, set `span = .between` and verify a following chord
  exists in the same voice. The follower chord, if it itself has a
  `<Tremolo>` block (MuseScore writes both sides), has its `tremolo`
  field cleared in the same pass — only the start chord carries the
  Swift model value, and the follower's `c*` token is discarded as
  redundant.
- Unknown subtype → `SheetMusicError.malformedScore`.
- Missing pair partner → `SheetMusicError.malformedScore`.

### MSCX encode

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`: when a chord
has `.tremolo != nil`, emit a `<Tremolo>` block with the subtype and
(if non-default) `<strokeStyle>`. For two-note tremolo, emit the same
block on the follower chord as well (MuseScore round-trip parity).

The "MuseScore writes `<Tremolo>` blocks in `Chord::write` order"
comment at `MSCXEncoder+Chord.swift:40` is replaced by the
implementation; remove the stub comment.

### MIDI render

`Sources/SheetMusicMIDI/Render/MidiRenderer+Tremolo.swift` (new):

```swift
extension MidiRenderer {

    /// Expand a chord's tremolo into a list of (pitchSet, durationTicks)
    /// segments. Caller emits note-on/off events from this list using the
    /// same pipeline as a normal chord. `followerChord` is the next
    /// chord in the same voice — resolved by the caller's voice walk
    /// since the Tremolo value does not carry a back-pointer.
    func tremoloSegments(
        for chord: Chord,
        nominalDuration: Int,
        followerChord: Chord?
    ) -> [TremoloSegment] {
        guard let trem = chord.tremolo else { return [...] }   // no tremolo: single segment

        let strokes = 1 << Int(trem.subtype.rawValue)  // r8=2, r16=4, r32=8
        switch trem.span {
        case .single:
            let dur = nominalDuration / strokes
            return Array(repeating: TremoloSegment(pitches: chord.pitches, ticks: dur),
                         count: strokes)
        case .between:
            guard let follower = followerChord else { /* malformedScore */ }
            let totalDur = nominalDuration                  // pair shares the written value
            let perStroke = totalDur / strokes
            return (0..<strokes).map { i in
                TremoloSegment(
                    pitches: (i.isMultiple(of: 2) ? chord : follower).pitches,
                    ticks: perStroke
                )
            }
        }
    }
}
```

`TremoloSegment` is a tiny internal helper struct in the same file.
Integration into `MidiRenderer+Voice.swift`:

- When walking voice events, if a chord has tremolo, look up the
  follower (if `.between`) by scanning forward in the same voice's
  flattened event list (the pair partner is also a `Chord`, never a
  rest), then call `tremoloSegments(...)` and emit note-on / note-off
  for each segment instead of one note-on per chord.
- Mark the follower chord with a "consumed by tremolo" flag so the
  voice walk's next iteration skips its own emission — both halves of
  the pair share a single rendered segment list.
- Existing tie / slur / velocity passes operate on the produced
  note-on list unchanged.

Reference: MuseScore `engraving/dom/tremolo.cpp` (`Tremolo::tremoloLen`)
and `engraving/playback/renderer/internal/tremolorenderer.cpp`.

### Layout

`Sources/SheetMusicLayout/Layout/LayoutEngine+Beaming.swift` is the
right home: tremolo bars are a beam-family shape.

- New `LayoutElement` case (or reuse beam metrics in a new struct):
  `.tremoloBars(anchor: TremoloAnchor, barCount: Int)`
- `TremoloAnchor`:
  - `.single(stemSegment: SegmentRef)` — bars centered on the stem
  - `.between(leftStem: SegmentRef, rightStem: SegmentRef)` — bars
    span from one stem to the other
- Bar count comes from `subtype.rawValue` (1, 2, or 3).
- Slant: fixed `+12°` for v1; matches MuseScore default sufficiently.
- Bar thickness and spacing reuse `metrics.beamThickness` and
  `metrics.beamSpacing`.

The placement pass (`LayoutEngine+Placement.swift`) emits this element
after the chord's stem is finalized.

### UI

`Sources/SheetMusicUI/Rendering/TremoloRenderer.swift` (new). Reads the
`.tremoloBars` element and draws each bar as a SwiftUI `Path` rectangle
with the slant applied. Bar drawing helper can be lifted from / shared
with `BeamRenderer.swift` if a clean extraction is cheap; otherwise
inline.

### Tests

`Tests/SheetMusicTests/Tremolo/`:

- `TremoloMSCXDecodeTests`:
  - `r8` on a quarter note → `.single`, subtype `.r8`
  - `c16` on a pair of half notes → first chord has `.between`, second
    chord has `tremolo == nil`
  - Unknown subtype → throws `.malformedScore`
  - Trailing `c*` with no follower → throws `.malformedScore`
- `TremoloMSCXEncodeTests`:
  - Round-trip `r16` and `c8` through decode → encode → decode and
    verify equal Score subtree.
- `TremoloMIDIRenderTests`:
  - Quarter + `.r16` → 4 note-ons at quarter/4 spacing on the chord
    pitches
  - Two halves + `.c8` → 4 note-ons total, alternating pitch sets
  - `.z` stroke style currently renders identically to `.traditional`
    (regression test guards the v1 behavior; update when implemented)

Any MuseScore fixture under `Tests/SheetMusicTests/Resources/` that
contains tremolo (search for `<Tremolo>` after this lands) is
automatically covered by `MidiExportTests` semantic equivalence.

---

## Phase 2 — MusicXML `<glissando>` / `<slide>` import

### Scope

Read both `<glissando>` and `<slide>` from MusicXML / MXL files and
attach `Glissando` model values to the corresponding start `Note`.
Export side untouched (no MusicXML exporter exists today).

### Mapping

| MusicXML element / attribute | `Glissando` field |
|---|---|
| `<glissando>` (any `line-type`) | `style = .chromatic` |
| `<slide>` (any `line-type`) | `style = .portamento` |
| `line-type="wavy"` | `visualType = .wavy` |
| `line-type="solid"` / `"dashed"` / `"dotted"` / absent | `visualType = .straight` |
| element text content | `text` |
| `type="start"` | start side; record in pending dict keyed by `number` |
| `type="stop"` | look up start side, attach `Glissando` to start `Note` |
| `number` attribute (default `"1"`) | pairing key (per-part scope) |
| (no MusicXML equivalent) | `easeIn = 0`, `easeOut = 0` |

`<glissando line-type="dashed">` and `"dotted"` collapse to `.straight`
in v1; a follow-up may extend `Glissando.VisualType`.

### Parsing implementation

`Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift` gains
a glide handler invoked from the `<notations>` walk:

```swift
private struct PendingGlide {
    let style: Glissando.Style
    let visualType: Glissando.VisualType
    let text: String?
    let startNoteIndex: Int     // index into the part's emitted notes
}

// keyed by (kind, number); kind = "glissando" | "slide"
private var pendingGlides: [GlideKey: PendingGlide] = [:]
```

On `type="start"`: build `PendingGlide`, store under
`(kind, number)`. On `type="stop"`: look up; if found, mutate the
start note (`notes[start.startNoteIndex].glissando = Glissando(...)`);
if not found, log a warning equivalent (or simply drop — the existing
permissive-parser convention).

The pending dict lives on the decoder instance and is cleared at part
boundary (`<part>` close). Cross-part `<glissando>` is invalid in
MusicXML, so this is safe.

### Tests

Fixtures (small, hand-authored, MIT under `Sources/`-equivalent
authorship — these go under `Tests/SheetMusicTests/Resources/` like
other test fixtures):

- `glissando-wavy.musicxml` — two chromatic-line-wavy notes
- `slide-portamento.musicxml` — two slide notes
- `glissando-unmatched-stop.musicxml` — stop with no start, must not
  crash

`MusicXMLGlissandoTests`:

- Decode `glissando-wavy.musicxml` → start note has
  `Glissando(style: .chromatic, visualType: .wavy, ...)`
- Decode `slide-portamento.musicxml` → start note has
  `Glissando(style: .portamento, ...)`
- Decode `glissando-unmatched-stop.musicxml` → succeeds with no
  glissando attached (permissive)

---

## Phase 3 — Diatonic glissando key signature awareness

### Current behavior

`Sources/SheetMusicMIDI/Render/MidiRenderer+GlissandoMath.swift`
(`renderDiscreteGlissando` `.diatonic` branch) walks the hard-coded
C-major pitch class set `{0, 2, 4, 5, 7, 9, 11}`. Result: a G-major or
F-minor piece with a `style = .diatonic` glissando produces tonally
incorrect intermediate pitches.

### Target behavior

Use the active key signature at the glissando start tick to derive a
seven-tone pitch class set, then walk those pitch classes from start
to end pitch.

Algorithm: start from the C-major pitch class set
`{0, 2, 4, 5, 7, 9, 11}`. Walk the circle-of-fifths order — sharps
F C G D A E B (raise by 1), flats B E A D G C F (lower by 1) — and
apply `|concertKey|` alterations. Each alteration replaces one PC with
its neighbor; the resulting set always has exactly seven elements.

Resulting table (sharps positive, flats negative; each row has exactly
7 pitch classes):

| Signature | Pitch classes (0=C) |
|---|---|
| 0 (C / A min)     | 0 2 4 5 7 9 11 |
| +1 (G / E min)    | 0 2 4 6 7 9 11 |
| +2 (D / B min)    | 1 2 4 6 7 9 11 |
| +3 (A / F# min)   | 1 2 4 6 8 9 11 |
| +4 (E / C# min)   | 1 3 4 6 8 9 11 |
| +5 (B / G# min)   | 1 3 4 6 8 10 11 |
| +6 (F# / D# min)  | 1 3 5 6 8 10 11 |
| +7 (C# / A# min)  | 0 1 3 5 6 8 10 |
| −1 (F / D min)    | 0 2 4 5 7 9 10 |
| −2 (Bb / G min)   | 0 2 3 5 7 9 10 |
| −3 (Eb / C min)   | 0 2 3 5 7 8 10 |
| −4 (Ab / F min)   | 0 1 3 5 7 8 10 |
| −5 (Db / Bb min)  | 0 1 3 5 6 8 10 |
| −6 (Gb / Eb min)  | 1 3 5 6 8 10 11 |
| −7 (Cb / Ab min)  | 1 3 4 6 8 10 11 |

(Major / minor share the same key signature, so a single mapping
suffices regardless of mode. ±6 produce enharmonically equivalent PC
sets — F# major and Gb major both round to `{1, 3, 5, 6, 8, 10, 11}` —
which is correct for playback.)

### Implementation

1. Inspect `Sources/SheetMusicCore/Score/KeySignature.swift` for an
   existing PC-set helper. If absent, add:
   ```swift
   public extension KeySignature {
       /// 7-tone pitch class set (0..11) of the diatonic scale implied
       /// by this signature. Major / minor / modal share the same
       /// signature so a single mapping suffices.
       var diatonicPitchClasses: Set<Int> { ... }
   }
   ```
2. Update `MidiRenderer+GlissandoMath.swift` `.diatonic` branch:
   - Replace hard-coded `cMajorPCs` constant with a `pcSet: Set<Int>`
     parameter.
3. Update the caller in `MidiRenderer+Glissando.swift` to resolve the
   active key at the glissando start tick via the existing
   `Score.activeKey(at:)` helper, then call
   `keySignature.diatonicPitchClasses` for `pcSet`.

Transposing instruments: the glissando's start/end pitches are already
written in concert pitch in the MIDI render pipeline, so the concert
key signature is the right source. No additional transposition logic
required.

### Edge cases

- **Modulation inside a glissando span.** Use the key at start tick;
  matches MuseScore.
- **Atonal piece (no explicit key signature).** Defaults to C major →
  same behavior as today.
- **Polytonal score (per-staff key).** Use the start chord's staff's
  active key.

### Tests

`Tests/SheetMusicTests/MIDIRender/GlissandoDiatonicKeyTests`:

- C major, glissando C4 → C5: intermediate pitches must include E4 and
  not include Eb4
- G major, glissando G3 → G4: intermediate pitches must include F#4
  and not include F4
- F minor (signature −4), glissando F3 → F4: intermediate pitches must
  include Ab3, Bb3, Db4, Eb4

### Doc update

`MidiRenderer+GlissandoMath.swift:68` comment: replace the "major-scale
approximation" note with a description of the new key-signature-aware
behavior and the remaining staff-line divergence (Tab clef, non-five-
line staves).

---

## Phasing and dependencies

- **Phase 1 (tremolo)** is self-contained.
- **Phase 2 (MusicXML glissando)** depends only on the existing
  `Glissando` model. Independent of Phase 1.
- **Phase 3 (diatonic key signature)** depends on the existing
  `Glissando` model and a `KeySignature.diatonicPitchClasses` helper.
  Independent of Phases 1 and 2.

All three can be implemented in any order; the brainstormed order
matches user authorization. Each phase ships as its own subagent
batch within the implementation plan.

## Risks

- **Tremolo pair resolution by adjacency.** If a consumer inserts an
  intervening chord between an `.between` start and what was the
  follower, the tremolo silently re-pairs to the new neighbor.
  Mitigation: this matches MuseScore's editor behavior (insertions
  inside a two-note tremolo are how the user *changes* the pair) and
  keeps the model free of back-pointers. Document the convention in
  `Tremolo.Span.between` doc comment.
- **MusicXML pending-dict scope.** Cross-`<part>` glissando is invalid
  but a malformed file could include one. Clearing at `</part>` and
  silently dropping orphan stops keeps the parser permissive without
  crashing.
- **Enharmonic PC-set collapse at ±6 / ±7.** F# major (+6) and Gb major
  (−6) produce identical pitch class sets, as do most ±7 pairings.
  This is correct for MIDI playback (no enharmonic distinction at the
  pitch-class level) but means the diatonic walk through such a
  glissando is not visually distinguishable from its enharmonic twin.
  Acceptable for v1.
