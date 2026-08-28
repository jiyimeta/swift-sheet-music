# Edit-command coverage

Inventory of MuseScore-style score-editing operations against this
package's `Score` data model. Use it to plan further edit-command
work without re-deriving the universe each time.

The model lives in `Sources/SheetMusicCore/Score/`. The active
edit-command implementations live in
`Sources/SheetMusicCore/Editing/`.

---

## Policy: implement composables as named commands too

Many edit operations can in principle be expressed as a Composite
of one or two `ReplaceVoiceElement` calls plus some inline data
mutation by the caller. That's "composable" — no new
domain-specific algorithm is required.

**We still implement those as named `EditCommand` values, marked
in DocC as sugar.** The named-command form earns its keep on three
axes:

1. **Intent** — `SetTie(from:to:...)` reads as a music-theory
   operation; the equivalent Composite of two ReplaceVoiceElement
   constructions reads as plumbing.
2. **Centralised validation** — even when the validation is
   minimal (e.g. "noteIndex in range"), having one place that
   owns it avoids drift across consumers.
3. **Future re-use** — additional consumers (CLI, tests, plugins,
   future editors) get the same named operation for free.

The DocC convention used to mark a sugar command:

```swift
/// > Note: This command is sugar over
/// > `ReplaceVoiceElement` (× N) + `CompositeEditCommand`. It
/// > exists to give the operation a domain-meaningful name and
/// > to centralise the small bit of validation it performs;
/// > callers can equally well construct the equivalent
/// > Composite directly.
```

When a command's body is purely a Composite over primitives,
include this note. When it has a non-trivial algorithm
(`SetChordDuration`, `PasteVoiceElement{,s}`, `CompositeEditCommand`,
`ReplaceVoiceElement{,s}`), no note is needed — those carry their
own substantive logic.

---

## A. Implemented

| Command | Trigger in macOS example | Sugar? |
| --- | --- | --- |
| `SetNotePitch` | ↑ / ↓ (±1 semitone) | — |
| `SetAccidental` | toolbar (♭♭ ♭ ♮ ♯ 𝄪 + clear) | sugar |
| `AddNoteToChord` | Shift+letter | sugar |
| `RemoveNoteFromChord` | Shift+Backspace | sugar |
| `DeleteVoiceElement` | Backspace / forward Delete | sugar |
| `SetTie` | `+` | sugar |
| `SetLyrics` | ⌘L (inline TextField) | sugar |
| `SetChordDuration` | 1..7 (chord selected) | — |
| `SetRestDuration` | 1..7 (rest selected) | — |
| `ReplaceVoiceElement` | primitive (used by note-input letter keys) | primitive |
| `ReplaceVoiceElements` | primitive | primitive |
| `PasteVoiceElement` | ⌘V (single, cross-measure spill) | — |
| `PasteVoiceElements` | ⌘V (range, multi-element, cross-measure spill, tuplet-aware) | — |
| `InsertMeasure` | menu command (structural) | — |
| `DeleteMeasure` | menu command (structural) | — |
| `SetRehearsalMark` | menu command (system lane) — set / rename a bar's mark | — |
| `RemoveRehearsalMark` | menu command (system lane) — clear a bar's mark | — |
| `CompositeEditCommand` | infrastructure for atomic multi-step edits | infrastructure |

Undo / redo is delivered by `ScoreEditor` (one inverse per applied
command).

---

## B. To-do checklist

The data model already supports each of these. Each item is a
candidate library command. Sugar items are explicitly tagged so
the implementer knows the body will be a thin Composite — but
they're still part of the implementation queue (per the policy
section above).

### Structural

- [ ] **`CreateTuplet`** — convert a range of consecutive timed
  elements into a tuplet (Ctrl+3 = triplet, Ctrl+5 = quintuplet, …).
  Modifies `Voice.tuplets` + rebuilds element durations.
- [ ] **`RemoveTuplet`** — drop a tuplet wrapper and restore its
  constituents to ordinary durations.
- [ ] **`MoveToVoice`** — move a chord or rest from one voice to
  another within the same measure.
- [x] **`InsertMeasure`** / **`DeleteMeasure`** — measure-level
  structural ops. Implemented; see "A. Implemented" above.
- [ ] **`SetBarLineSubtype`** *(sugar)* — change a barline
  (regular / double / repeat / end).
- [ ] **`SetMeasureRepeat`** — replace a measure's content with a
  measure-repeat sign.

### Score symbols (already present as `VoiceElement` cases)

- [ ] **`SetClef`** at a position — including mid-measure clef
  changes.
- [ ] **`SetKeySignature`** at a position.
- [ ] **`SetTimeSignature`** at a measure start — with downstream
  tick-budget recompute.
- [ ] **`SetTempo`** *(sugar)* — insert / edit / remove a tempo
  marking.
- [ ] **`SetDynamic`** *(sugar)* — pp / p / mf / f / ff / etc.
- [ ] **`SetStaffText`** *(sugar)* — arbitrary text label.
- [x] **`SetRehearsalMark`** / **`RemoveRehearsalMark`** — set /
  rename / remove the mark on one bar. Implemented; see
  "A. Implemented" above.
- [ ] **`SetFermata`** *(sugar)* — toggle fermata after / over an
  element.

### Note / Chord properties (fields already exist on the model)

- [ ] **`SetArpeggio`** *(sugar)* — `Chord.arpeggio`.
- [ ] **`SetGlissando`** *(sugar)* — `Note.glissando`.
- [ ] **`SetNoteHeadType`** *(sugar)* — `Note.headType` (cross /
  diamond / triangle / …).
- [ ] **`SetDots`** *(sugar)* — augmentation dot (`.fraction(...)`);
  thin wrapper over `SetChordDuration`.

### Range operations (composable from existing per-element
commands + `CompositeEditCommand`)

These iterate an existing per-element command across a `.range`
selection. Sugar all the way down — but worth a named API for
intent.

- [ ] **`TransposeRange`** *(sugar)* — by ±N semitones / octaves;
  loops `SetNotePitch`.
- [ ] **`AddIntervalToSelection`** *(sugar)* — third / fifth above
  or below; loops `AddNoteToChord` with computed pitches.
- [ ] **`DeleteRange`** *(sugar)* — replace each timed element in
  the range with rests; loops `DeleteVoiceElement`.
- [ ] **`SetAccidentalsInRange`** *(sugar)* — apply one accidental
  to every selected note; loops `SetAccidental`.
- [ ] **`SetDurationInRange`** *(sugar)* — set the same duration
  on every selected timed element; loops
  `SetChord/RestDuration`.
- [ ] **`RespellRange`** *(sugar)* — re-spell a range as natural
  / sharp / flat; loops `SetAccidental`.

### Spanners (depends on `Spanner` subtype coverage)

- [ ] **`SetSlur`** — phrase mark.
- [ ] **`SetHairpin`** — crescendo / decrescendo.
- [ ] **`SetPedal`** — piano pedal.
- [ ] **`SetVolta`** — repeat 1./2. brackets.
- [ ] **`SetOttava`** — 8va / 8vb octave lines.

---

## C. Out of scope for the current data model

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

Roughly ordered by impact. A reasonable sweep:

1. `CreateTuplet` / `RemoveTuplet` — rhythm editing core.
2. `SetDots` — cheap, but unlocks dotted durations from the
   keyboard.
3. `InsertMeasure` / `DeleteMeasure` — structural foundation.
4. Range commands (`TransposeRange` / `DeleteRange` /
   `SetAccidentalsInRange` / …) — pure sugar, ergonomic wins for
   the editor UX.
5. Text-mark commands together (`SetTempo` /`SetDynamic` /
   `SetStaffText`) — shared shape, easy to batch.
   (`SetRehearsalMark` / `RemoveRehearsalMark` have landed already —
   see "A. Implemented" above.)
6. Chord/note property commands (`SetArpeggio` / `SetGlissando` /
   `SetNoteHeadType`) — small, isolated.
7. `MoveToVoice` — voice editing.
8. Spanner commands once `Spanner` subtypes are confirmed.
