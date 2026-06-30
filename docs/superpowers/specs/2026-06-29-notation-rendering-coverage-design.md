# Notation rendering coverage expansion — design

**Date:** 2026-06-29
**Status:** Approved (design); implementation plan to follow.
**Scope target chosen by user:** noteheads = *all* MuseScore groups; notehead
*size* (small/cue) = yes; accidentals = *all* MuseScore types; upstream
"unsupported element" diagnostics = yes.

## Problem

Several engraved elements parse successfully but are silently dropped to a
default glyph at render time, with no diagnostic. The user-visible example: a
**cross+circle** notehead (`xcircle`) renders as a plain oval notehead. The
same silent-fallback pattern affects most notehead groups, all but five
accidentals, vibrato lines, and (cosmetically) wavy glissandi. Because the
fallback is silent, the downstream Folino iOS app — which reports unsupported
elements to Crashlytics from parse-time `ScoreDiagnostic`s — never learns the
notehead was unsupported, so production telemetry under-reports the gap.

## Goals

1. Render **all** MuseScore notehead groups (type) at the correct SMuFL glyph,
   including whole/half/quarter/double-whole variants and stem-direction
   variants where MuseScore distinguishes them.
2. Render **small / cue** noteheads at reduced magnification.
3. Render **all** MuseScore accidental types, including the parenthesis /
   bracket enclosure (a separate field in MuseScore).
4. Render **vibrato** lines (4 subtypes) as the correct repeated SMuFL wiggle
   glyph, instead of a plain text line.
5. Render **wavy glissando** with MuseScore's repeated `wiggleGlissando` glyph
   instead of a hand-drawn zigzag.
6. Emit a `ScoreDiagnostic(.warning)` at decode time for any element whose
   subtype the renderer genuinely cannot draw (truly-unknown / `custom`), so
   the existing Folino pipeline reports it with no Folino code change.
7. Produce a hand-authored `.mscz` **fixture** containing all of the above and
   copy it to `~/Desktop` for visual comparison against MuseScore.
8. Investigate and **document** (proposal only, no code) why Folino did not
   report the unsupported notehead, and how the upstream diagnostics fix it.

## Non-goals

- MusicXML / MXL accidental & notehead coverage parity. MusicXML's decoder
  keeps its current behaviour (`default: return nil`); it is not exhaustive
  over `Accidental`, so the enum expansion does not break it. Expanding the
  MusicXML import surface is out of scope.
- Playback / MIDI semantics. Accidentals are display-only (MIDI uses `pitch`
  directly); noteheads, vibrato, and glissando visuals do not change MIDI.
  Vibrato MIDI modulation is out of scope.
- Microtonal *playback* pitch from quarter-tone accidentals.
- The spanner-level `Spanner.Kind.glissando` → `.textLine` path (note-attached
  `Note.glissando` is the live path). Left as-is; noted as a known dead branch.

## Source-of-truth tables (studied from MuseScore, re-expressed)

The upstream MuseScore C++ (GPL-3.0, local clone `~/Developer/musescore/
MuseScore`) is used as a behavioural spec only — no code is copied. The glyph
*mappings* (group→SymId, type→SymId) are facts re-expressed as our own Swift
tables, with `/// C++: …` provenance comments citing the source line, exactly
as the project already does elsewhere. SMuFL codepoint **values** come from
`fonts/smufl/glyphnames.json` (SMuFL/OFL data — codepoint integers are facts).

To avoid hand-transcription error across ~75 notehead groups and ~80 accidental
types, the codepoint tables are **generated** by a dev script that joins
(a) the studied MuseScore group→SymId / type→SymId mapping with
(b) `glyphnames.json` name→codepoint, and emits committed Swift source. The
generated files carry a header noting provenance and that they are generated.
The script lives under `Scripts/` (or a dev-only target); the *output* is
normal committed `Sources/` Swift.

### Notehead table (MuseScore `src/engraving/dom/note.cpp:89-322`)

`static const SymId noteHeads[2][HEAD_GROUPS-1][HEAD_TYPES]` — dimension 0 is
stem direction (`[0]`=down, `[1]`=up), column order is
`{whole, half, quarter, double-whole}` per `NoteHeadType`
(`types.h:445-452`). 75 groups (`types.h:470-557`); `HEAD_CUSTOM` excluded.

- Down- and up-stem tables are identical **except** four groups:
  `HEAD_LARGE_ARROW` (arrow up vs down), `HEAD_SLASH` (brevis column),
  `HEAD_LARGE_DIAMOND` (brevis column), `HEAD_FA` (triangle-right vs -left).
- mscx `<head>` token = `TConv::toXml(NoteHeadGroup)` name string
  (`typesconv.cpp:1145-1235`). Named-pitch tokens carry a `-name` suffix
  (`"a-sharp-name"`, `"h-name"`); shape-note tokens are bare (`"sol"`, `"do"`).
  Brevis-alt's token is **`"altbrevis"`** (not `"brevis-alt"`).
- Representative SymIds: `xcircle` → `noteheadCircleX{,Half,Whole,DoubleWhole}`;
  `slash` → `noteheadSlashHorizontalEnds` / `noteheadSlashWhite{Whole,Half}`;
  shape notes → `noteShape*` range; named-pitch → `note<Pitch>[Sharp|Flat]*`.

### Accidental table (MuseScore `src/engraving/dom/accidental.cpp:51-224`)

`static const Acc ACC_LIST[]` is index-parallel to `enum AccidentalType`
(`accidental.h:35-212`). `subtype2symbol(st) = ACC_LIST[int(st)].sym`. The
mscx `<subtype>` string is the **SymId name** (`SymNames::nameForSymId`),
e.g. `SHARP` → `accidentalSharp`, `MIRRORED_FLAT` →
`accidentalQuarterToneFlatStein`.

- **Parentheses / brackets are a separate `<bracket>` int field**
  (`AccidentalBracket`: 0 none / 1 parenthesis / 2 bracket / 3 brace-deprecated,
  `accidental.h:218-223`). Resolved to enclosure glyphs at layout time
  (`tlayout.cpp:553-562`): paren → `accidentalParensLeft/Right`
  (U+E26A/E26B), bracket → `accidentalBracketLeft/Right` (U+E26C/E26D).
- **Combined-glyph special case** (`tlayout.cpp:535-551`): the 5 standard
  accidentals with a parenthesis (and no note-level paren) use a single
  combined SymId instead of left+acc+right: `accidentalFlatParens`,
  `accidentalDoubleFlatParens`, `accidentalNaturalParens`,
  `accidentalSharpParens`, `accidentalDoubleSharpParens`. (These are
  MuseScore-private SymIds; codepoints resolved from MuseScore's metadata.)
- `pitchOffset` / `centOffset` columns in `ACC_LIST` feed the semitone shift;
  microtonal types take the integer part (0 where purely cents).

### Vibrato (MuseScore `tlayout.cpp:6447-6462`, `vibrato.cpp:49-67`)

`VibratoType` (`types.h:1172-1178`), mscx `<subtype>` tokens
(`typesconv.cpp:3209-3215`). Each subtype repeats a **single** glyph along the
whole line (no distinct end cap):

| subtype token         | SymId                     | codepoint |
|-----------------------|---------------------------|-----------|
| `guitarVibrato`       | `guitarVibratoStroke`     | U+EAB2    |
| `guitarVibratoWide`   | `guitarWideVibratoStroke` | U+EAB3    |
| `vibratoSawtooth`     | `wiggleSawtooth`          | U+EABB    |
| `vibratoSawtoothWide` | `wiggleSawtoothWide`      | U+EABC    |

Count = `lrint((width - advance(glyph)) / advance(glyph))`.

### Glissando (MuseScore `tdraw.cpp:1549-1620`)

`GlissandoType { STRAIGHT=0, WAVY=1 }`; mscx tokens `"0"` / `"1"`.
- STRAIGHT: a drawn line (current behaviour is correct).
- WAVY: `floor(length / advance)` copies of **`wiggleGlissando`** (U+EAAF),
  centered horizontally, vertically centered on the line. (Not `wiggleTrill`.)

## Architecture & surfaces to touch

Confirmed by code survey:

- **Runtime renderer is CALayer** (`ScoreLayerBuilder*`); the SwiftUI `Canvas`
  renderers (`NoteheadRenderer`, `AccidentalRenderer`, `SpannerRenderer`,
  `GlissandoRenderer`) are legacy but kept in parity.
- Glyph-based elements (notehead, accidental) resolve their codepoint through
  the shared `SheetMusicLayout` tables `NoteheadGlyph` / `AccidentalGlyph`,
  which **both** renderers and the Android `LayoutBridge` call. Extending those
  tables benefits all three render paths automatically.
- Layout carries `LayoutChordNote.headType: String?` (raw token), not a cached
  codepoint — so new notehead glyphs need changes only in `NoteheadGlyph`
  (+ a stem-direction parameter; see below).
- Android `DrawProgram` (`Sources/SheetMusicAndroidJNI/Draw/DrawProgram.swift`)
  supports glyph-by-codepoint, moveTo/lineTo/stroke, cubicTo, setColor — so
  both glyph-repeat wiggles and stroked paths cross the wire.

### Core model (`Sources/SheetMusicCore`)

- `Accidental` (`Score/Accidental.swift`): expand from 5 cases to the full
  MuseScore `AccidentalType` set. Decode/encode via the SMuFL SymId-name token
  (`init?(mscxSubtype:)` / `var mscxSubtype`). Keep it display-only.
- New `AccidentalBracket` enum (`none` / `parenthesis` / `bracket`). Add
  `Note.accidentalBracket: AccidentalBracket = .none`.
- `Note.isSmall: Bool = false` (small/cue notehead). `<small>` on `<Chord>`
  propagates to its notes at decode (or a `Chord.isSmall` consulted by layout —
  decided in plan; default to per-note propagation for minimal layout change).
- `Spanner.Kind`: add `.vibrato`. Add `Spanner.vibrato: VibratoPayload?` with a
  `VibratoType` enum (4 cases). Update the two exhaustive switches over
  `Spanner.Kind` (`LayoutEngine+Spanners.isBelowStaff`, `…layoutKind`).
- `PitchSpelling.semitoneShift` exhaustive switch: drive from the accidental
  pitchOffset table (microtonal → integer part).

### Decode (`Sources/SheetMusicMSCX/Decoders`)

- `MSCXDecoder+Note`:
  - `decodeHeadType`: normalize MS2 integer codes **to MS4 tokens** (fix
    `alt-brevis`→`altbrevis` etc.); pass MS3+ strings through; emit
    `mscx.note.unsupportedHeadType` (warning) for unknown codes / unknown
    strings / `custom`.
  - Accidental: decode `<subtype>` (SymId-name) → full `AccidentalType`;
    decode `<bracket>` int → `AccidentalBracket`; emit
    `mscx.accidental.unsupportedSubtype` for unknown subtypes.
  - Decode `<small>` → `Note.isSmall`.
- `MSCXDecoder+Spanner`: decode `<Spanner type="Vibrato">` → `.vibrato` kind +
  `VibratoPayload` from `<Vibrato><subtype>`; emit
  `mscx.vibrato.unknownSubtype` for unknown subtypes.

### Layout (`Sources/SheetMusicLayout`)

- `Engraving/NoteHeadGroup.swift` (new): the `NoteHeadGroup` enum, MS4
  token→group resolver, and the `noteHeads[group][type]` table (stem-direction
  branch for the 4 differing groups).
- `Engraving/NoteheadGlyph.swift`: rewrite `codepoint(duration:headType:
  stemUp:)` to resolve token→group→SymId→codepoint via the table.
- `Engraving/AccidentalGlyph.swift`: rewrite to the full `AccidentalType`
  table; add enclosure-glyph resolution (paren/bracket left+right, plus the
  5-standard combined-glyph case).
- `Engraving/SMuFLCodepoints+Noteheads.swift`, `+Accidentals.swift`,
  `+Lines.swift` (new, generated): codepoint constants for the new glyphs,
  split to respect the 300-line file cap.
- `LayoutElement`: add `SpannerKind.vibrato`; add optional `mag` to the chord
  element (small-note magnification, mirroring `.graceChord`'s `mag`); carry
  the vibrato payload on the spanner element.
- `LayoutEngine+Placement`: apply `smallNoteMag = 0.7` to small chords/notes.
- `LayoutEngine+Spanners`: `layoutKind` maps `.vibrato` → `.vibrato`;
  `isBelowStaff` handles `.vibrato`.
- Accidental horizontal placement: replace the hardcoded `1.2 * sp` left offset
  (`ScoreLayerBuilder+Chord.swift:228`, `LayoutBridge+Chord.swift:172`) with a
  **measured-advance-width** offset via `FontMetricsProvider`, so wide glyphs
  (double-flat, quarter-tones, enclosures) don't collide with the notehead.

### Rendering

- **CALayer** (`ScoreLayerBuilder+{Spanners,Glissando,Chord}`): vibrato glyph
  repeat; wavy glissando glyph repeat; small-note scaled metrics; accidental
  enclosure glyphs.
- **Canvas** (legacy, parity): same changes in `SpannerRenderer`,
  `GlissandoRenderer`, `AccidentalRenderer`, `NoteheadRenderer`.
- **Android wire** (`LayoutBridge+{Engraving,Chord,Glissando}`): `.vibrato`
  spanner case (glyph-repeat ops); wavy glissando glyph-repeat ops; small-note
  mag; accidental enclosure glyphs. Add the `LayoutElement.SpannerKind.vibrato`
  case to the Android encoder switch.

### Diagnostics

- New diagnostic codes: `mscx.note.unsupportedHeadType`,
  `mscx.accidental.unsupportedSubtype`, `mscx.vibrato.unknownSubtype`
  (all `.warning`), emitted via `mscxDecoderWarn`, surfaced through
  `parseWithDiagnostics`.
- After this work the renderable set is large; "unsupported" means genuinely
  unknown / `custom` / future tokens. A **sync test** in the test target
  (which imports both MSCX and Layout) asserts the MSCX decoder's known-token
  set is exactly covered by the Layout renderable set, so a future glyph
  addition can't drift the two apart silently.

## Error handling

Follows the existing three-way MSCX policy: notehead/accidental/vibrato subtype
anomalies are **embellishment-class** → drop to a safe default (standard
notehead / no accidental / plain line) **and** emit a `.warning`
`ScoreDiagnostic`. Nothing here is structural; the score always loads.

## Testing

- Unit tests (Swift Testing): notehead token→codepoint for a representative
  sample across families incl. stem-direction groups; accidental
  type→codepoint incl. bracket/paren enclosure and the combined-glyph case;
  vibrato subtype→glyph; wavy glissando glyph-count geometry; small-note mag.
- Decode tests: `<head>` MS2-code→MS4-token normalization; `<small>`;
  `<subtype>`+`<bracket>`; `<Spanner type="Vibrato">`.
- Diagnostic tests: unknown headType/accidental/vibrato emit the right code;
  the MSCX-known ↔ Layout-renderable **sync test**.
- Round-trip: MSCX encode→decode for new accidental types + bracket + small.
- `Scripts/gate-android-tests.sh` after adding Apple-only tests.
- Green `swift test`; Mac + iOS `xcodebuild` (public-enum changes ripple into
  the example app — verify both per project convention).
- Visual: render the fixture in `SheetMusicExampleMac`; user compares against
  MuseScore opening the same `.mscz`.

## Fixture

Hand-author a MuseScore-4 `.mscx` (single instrument, several measures)
covering: a representative spread of notehead groups across whole/half/quarter;
small/cue notes; accidentals from each category (standard, quarter-tone,
parenthesized, bracketed, one exotic); vibrato ×4; glissando straight + wavy.
Zip to `.mscz`, copy to `~/Desktop`. Validate it parses with our own parser;
the user opens it in MuseScore for the side-by-side. The fixture is **not**
committed under `Tests/.../Resources` as a GPL fixture (it's our own authored
content) — its home and whether to commit a copy in-repo is decided in the
plan; the Desktop copy is the deliverable.

## Folino (investigation result + proposal only — no code change)

**Why the notehead was not reported.** Folino
(`Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift`)
collects diagnostics only from `MSCXParser/MSCZReader.parseWithDiagnostics`,
forwards `.warning`-severity ones via `ScoreDiagnosticReporter` →
`FirebaseCrashReporter.record(error:)`. swift-sheet-music emitted **no**
diagnostic for notehead/accidental/vibrato fallbacks (only tremolo / breath /
score-version warn today). `xcircle` parsed cleanly (code 6 → `"xcircle"`) and
fell back silently at render time → nothing to report. Root cause is upstream.

**Proposal (to implement later, separately):**
1. Bump the swift-sheet-music dependency to the version shipping the new
   `mscx.note.unsupportedHeadType` / `…accidental…` / `…vibrato…` diagnostics.
   Folino's existing pipeline then reports genuinely-unsupported elements with
   **no Folino code change**.
2. (Separate gap, optional) `LiveScoreFileGateway` returns `[]` diagnostics for
   MusicXML / MXL / MIDI — those formats never report anything. Note for future
   work; out of scope for this fix.

## Implementation phases (for the plan)

Independent enough to sequence or parallelize:

- **P1** Notehead types: generated table + `NoteHeadGroup` + `NoteheadGlyph`
  (stem-dir) + decoder token normalization + tests.
- **P2** Notehead size: `Note.isSmall` + decode + layout mag + renderers.
- **P3** Accidentals: `Accidental` expansion + `AccidentalBracket` + generated
  table + `AccidentalGlyph` + decoder + encoder + measured-width placement +
  all exhaustive-switch updates + tests.
- **P4** Vibrato: `Spanner.Kind.vibrato` + payload + decode + layout + 3 render
  paths + tests.
- **P5** Glissando wavy: `wiggleGlissando` glyph-repeat in geometry + 3 render
  paths + tests.
- **P6** Diagnostics + MSCX↔Layout sync test.
- **P7** Fixture authoring + Desktop copy + visual verification.
- **P8** Folino proposal doc (no code).
