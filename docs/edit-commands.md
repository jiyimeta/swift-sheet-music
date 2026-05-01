# Edit-command coverage

Inventory of MuseScore-style score-editing operations against this
package's `Score` data model. Use it to plan further edit-command
work without re-deriving the universe each time.

The model lives in `Sources/SheetMusicCore/Score/`. The active
edit-command implementations live in
`Sources/SheetMusicCore/Editing/`.

---

## A. Implemented

| Command | Trigger in macOS example |
| --- | --- |
| `SetNotePitch` | ↑ / ↓ (±1 semitone) |
| `SetAccidental` | toolbar (♭♭ ♭ ♮ ♯ 𝄪 + clear) |
| `AddNoteToChord` | Shift+letter |
| `RemoveNoteFromChord` | Shift+Backspace |
| `DeleteVoiceElement` | Backspace / forward Delete |
| `SetTie` | `+` |
| `SetLyrics` | ⌘L (inline TextField) |
| `SetChordDuration` | 1..7 (chord selected) |
| `SetRestDuration` | 1..7 (rest selected) |
| `ReplaceVoiceElement` | primitive (used by note-input letter keys) |
| `ReplaceVoiceElements` | primitive |
| `PasteVoiceElement` | ⌘V (single, cross-measure spill) |
| `PasteVoiceElements` | ⌘V (range, multi-element, cross-measure spill, tuplet-aware) |
| `CompositeEditCommand` | infrastructure for atomic multi-step edits |

Undo / redo is delivered by `ScoreEditor` (one inverse per applied
command).

---

## B. Composable (no new library command needed)

These build on the existing primitives + `CompositeEditCommand`.
The macOS host can construct them inline in a key handler — no
library API surface required.

- Transpose range by ±N semitones — loop `SetNotePitch`.
- Transpose range by ±N octaves — loop `SetNotePitch` (12 semis).
- Add interval (third / fifth above-or-below) to a selection — loop
  `AddNoteToChord` with computed pitches.
- Delete a range (replace with rests) — loop `DeleteVoiceElement`.
- Apply one accidental to every selected note — loop
  `SetAccidental`.
- Set the same duration on every selected timed element — loop
  `SetChord/RestDuration`.
- Insert a chord/rest at an arbitrary beat — already covered by
  `PasteVoiceElement` (the cross-measure spill handles overflow).
- Re-spell a range as natural / sharp / flat — loop
  `SetAccidental(.natural | .sharp | …)`.

---

## C. To-do — need a new `EditCommand`

The data model already supports each of these. Each item is a
candidate library command.

### Structural

- [ ] **`CreateTuplet`** — convert a range of consecutive timed
  elements into a tuplet (Ctrl+3 = triplet, Ctrl+5 = quintuplet, …).
  Modifies `Voice.tuplets` + rebuilds element durations.
- [ ] **`RemoveTuplet`** — drop a tuplet wrapper and restore its
  constituents to ordinary durations.
- [ ] **`MoveToVoice`** — move a chord or rest from one voice to
  another within the same measure.
- [ ] **`InsertMeasure`** / **`DeleteMeasure`** — measure-level
  structural ops.
- [ ] **`SetBarLineSubtype`** — change a barline (regular / double /
  repeat / end).
- [ ] **`SetMeasureRepeat`** — replace a measure's content with a
  measure-repeat sign.

### Score symbols (already present as `VoiceElement` cases)

- [ ] **`SetClef`** at a position — including mid-measure clef
  changes.
- [ ] **`SetKeySignature`** at a position.
- [ ] **`SetTimeSignature`** at a measure start — with downstream
  tick-budget recompute.
- [ ] **`SetTempo`** — insert / edit / remove a tempo marking.
- [ ] **`SetDynamic`** — pp / p / mf / f / ff / etc.
- [ ] **`SetStaffText`** — arbitrary text label.
- [ ] **`SetRehearsalMark`** — A / B / C boxed labels.
- [ ] **`SetFermata`** — toggle fermata after / over an element.

### Note / Chord properties (fields already exist on the model)

- [ ] **`SetArpeggio`** — `Chord.arpeggio`.
- [ ] **`SetGlissando`** — `Note.glissando`.
- [ ] **`SetNoteHeadType`** — `Note.headType` (cross / diamond /
  triangle / …).
- [ ] **`SetDots`** — augmentation dot (`.fraction(...)`); could
  start as a thin wrapper over `SetChordDuration`.

### Spanners (depends on `Spanner` subtype coverage)

- [ ] **`SetSlur`** — phrase mark.
- [ ] **`SetHairpin`** — crescendo / decrescendo.
- [ ] **`SetPedal`** — piano pedal.
- [ ] **`SetVolta`** — repeat 1./2. brackets.
- [ ] **`SetOttava`** — 8va / 8vb octave lines.

---

## D. Out of scope for the current data model

These need a `Score` model extension before any edit command makes
sense.

| Feature | Required model addition |
| --- | --- |
| Articulations (staccato, accent, marcato, tenuto, …) | `articulations` array on `Note`/`Chord`. |
| Grace notes (acciaccatura / appoggiatura) | grace-note flag + position on `Chord`. |
| Tremolo | tremolo subtype on `Chord`. |
| Ornaments (turn, mordent, trill) | per-note ornament annotation. |
| Cue note (small) | `Chord`/`Note` scale / cue flag. |
| Note color / visibility | per-element color + visibility properties. |
| Stem direction override | `Chord.stemDirection` (currently auto only). |
| Beam mode override | `Chord.beamMode` (auto / break / continue). |
| Slash notation | dedicated voice element. |
| Figured bass / chord symbols | dedicated annotation type. |
| System / page break | edit path through `LayoutBreak`. |

---

## Suggested implementation order

The list in C above is roughly ordered by impact. A reasonable
sweep is:

1. `CreateTuplet` / `RemoveTuplet` — rhythm editing core.
2. `SetDots` — cheap, but unlocks dotted durations from the
   keyboard.
3. `InsertMeasure` / `DeleteMeasure` — structural foundation.
4. Text-mark commands together (`SetTempo` /`SetDynamic` /
   `SetStaffText` / `SetRehearsalMark`) — shared shape, easy to
   batch.
5. Chord/note property commands (`SetArpeggio` / `SetGlissando` /
   `SetNoteHeadType`) — small, isolated.
6. `MoveToVoice` — voice editing.
7. Spanner commands once `Spanner` subtypes are confirmed.
