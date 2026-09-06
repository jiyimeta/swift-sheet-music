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
| `InputNote` | note-input letter keys (writes a note into a rest) | — |
| `SetNotePitch` | ↑ / ↓ (±1 semitone) | — |
| `SetAccidental` | toolbar (♭♭ ♭ ♮ ♯ 𝄪 + clear) | sugar |
| `AddNoteToChord` | Shift+letter | sugar |
| `RemoveNoteFromChord` | Shift+Backspace | sugar |
| `DeleteVoiceElement` | Backspace / forward Delete | sugar |
| `SetTie` | `+` | sugar |
| `SetLyrics` | ⌘L (inline TextField) | sugar |
| `SetLyric` | not in the example — driven by `LyricInputPlanner` | sugar |
| `SetChordDuration` | 1..7 (chord selected) | — |
| `SetRestDuration` | 1..7 (rest selected) | — |
| `ReplaceVoiceElement` | primitive (used by note-input letter keys) | primitive |
| `ReplaceVoiceElements` | primitive | primitive |
| `PasteVoiceElement` | ⌘V (single, cross-measure spill) | — |
| `PasteVoiceElements` | ⌘V (range, multi-element, cross-measure spill, tuplet-aware) | — |
| `InsertMeasure` | menu command (structural) | — |
| `DeleteMeasure` | menu command (structural) | — |
| `CreateTuplet` | ⌘+digit on a non-tuplet element | — |
| `RemoveTuplet` | ⌘+digit on an existing tuplet member | — |
| `AddPart` | not in the example — driven by a host app's instruments sheet | — |
| `RemovePart` | not in the example — driven by a host app's instruments sheet | — |
| `MovePart` | not in the example — driven by a host app's instruments sheet | — |
| `SetKeySignature` | not in the example — driven by a host app's signature sheet | — |
| `RemoveKeySignature` | not in the example — driven by a host app's signature sheet | — |
| `SetTimeSignature` | not in the example — driven by a host app's signature sheet | — |
| `RemoveTimeSignature` | not in the example — driven by a host app's signature sheet | — |
| `SetStaffDefaultClef` | not in the example — driven by a host app's clef picker | — |
| `SetRehearsalMark` | menu command (system lane) — set / rename a bar's mark | — |
| `RemoveRehearsalMark` | menu command (system lane) — clear a bar's mark | — |
| `CreateVoice` | not in the example — the drum pad, writing into a voice the bar lacks | — |
| `SplitRest` | not in the example — the drum pad's column caret, landing inside a rest | — |
| `SetNoteHead` | not in the example — the drum pad, writing a cross-head hi-hat | sugar |
| `SetDrumsetEntry` | not in the example — the drum pad, repairing a kit that never named this drum | — |
| `SetPartNames` | not in the example — driven by a host app's instruments sheet | — |
| `SetLayoutBreak` | not in the example — host command registry | — |
| `SetBarLine` | not in the example — host command registry | sugar |
| `SetRepeatBarLines` | not in the example — host command registry | — |
| `SetMeasureRepeat` | not in the example — host command registry | — |
| `MoveToVoice` | not in the example — host command registry | sugar |
| `TransposeRange` | not in the example — host command registry | sugar |
| `AddIntervalToSelection` | not in the example — host command registry | sugar |
| `DeleteRange` | not in the example — host command registry | sugar |
| `SetAccidentalsInRange` | not in the example — host command registry | sugar |
| `SetDurationInRange` | not in the example — host command registry | sugar |
| `RespellRange` | not in the example — host command registry | sugar |
| `SetClef` | not in the example — host command registry | sugar |
| `RemoveClef` | not in the example — host command registry | sugar |
| `SetTempo` | not in the example — host command registry | — |
| `SetStaffText` | not in the example — host command registry | — |
| `SetDynamic` | not in the example — host command registry | sugar |
| `SetFermata` | not in the example — host command registry | sugar |
| `SetBreath` | not in the example — host command registry | sugar |
| `SetJumps` | not in the example — host command registry | — |
| `SetMarkers` | not in the example — host command registry | — |
| `SetArticulation` | not in the example — host command registry | sugar |
| `SetGraceNotes` | not in the example — host command registry | sugar |
| `SetTremolo` | not in the example — host command registry | sugar |
| `SetArpeggio` | not in the example — host command registry | sugar |
| `SetGlissando` | not in the example — host command registry | sugar |
| `SetDots` | not in the example — host command registry | sugar |
| `SetChordLine` | not in the example — host command registry | sugar |
| `SetNoteParentheses` | not in the example — host command registry | sugar |
| `SetElementVisible` | not in the example — host command registry | sugar |
| `SetNoteVisible` | not in the example — host command registry | sugar |
| `SetStemVisible` | not in the example — host command registry | sugar |
| `SetBeamVisible` | not in the example — host command registry | sugar |
| `SetSlur` | not in the example — host command registry | sugar |
| `SetHairpin` | not in the example — host command registry | sugar |
| `SetPedal` | not in the example — host command registry | sugar |
| `SetVolta` | not in the example — host command registry | sugar |
| `SetOttava` | not in the example — host command registry | sugar |
| `SetTextLine` | not in the example — host command registry | sugar |
| `SetTrill` | not in the example — host command registry | sugar |
| `SetVibrato` | not in the example — host command registry | sugar |
| `SetPalmMute` | not in the example — host command registry | sugar |
| `SetLetRing` | not in the example — host command registry | sugar |
| `RemoveSpanner` | not in the example — host command registry | sugar |
| `SetChordSymbol` | not in the example — host command registry | sugar |
| `CompositeEditCommand` | infrastructure for atomic multi-step edits | infrastructure |

Undo / redo is delivered by `ScoreEditor` (one inverse per applied
command).

Every command from `SetLayoutBreak` through `SetChordSymbol` is also an
`EditIntent` case (wire indices 30–73, `EditIntentCodec.swift`'s case
list) and a step of the frozen parity replay chain (`ReplayChain.parity`).
`CompositeEditCommand`, listed last as infrastructure, is not: it
predates the project and keeps its own earlier wire index.

---

## B. To-do checklist

Empty. Every operation the `Score` model can express has a named
command in §A — the edit-command parity project
(`docs/superpowers/specs/2026-09-02-edit-command-parity-design.md`,
intents 30–73) closed the queue this section used to hold. New
commands start with a gap from §C, or with a new feature
altogether; either way they open a new wire chain rather than extending
the frozen parity one (`ReplayChain`).

---

## C. Still out of reach

Everything else this checklist used to list here — articulations,
grace notes, tremolo, note color / visibility, stem/beam mode,
layout breaks, chord symbols, spanners — already existed in
`Sources/SheetMusicCore/Score/` and rendered; it only lacked an edit
command. The edit-command parity project
(`docs/superpowers/specs/2026-09-02-edit-command-parity-design.md`)
gave each one an edit command, landed in seven groups: Structural
(intents 30–34), Range (35–40), Marks (41–49), Note / chord (50–57),
Visibility (58–61), Spanners (62–72) and Harmony (73).

What is left below is the true remainder — the rows that need the
`Score` model to grow, plus the ones the parity groups recorded as
deliberately out of their v1 (each is a spec §3.4 amendment). Nothing
else is known to be missing:

| Feature | Why it is out of reach today |
| --- | --- |
| Ornaments other than trill (turn, mordent, …) | the model has `TrillType` (`SetTrill`, #68) but no general ornament case — a turn or mordent has nowhere to attach. |
| Manual stem direction | the model has no field for it — `Chord` carries `stemVisible` (`SetStemVisible`, #60), not a direction; MuseScore always computes it. |
| Cue note (small) | neither `Chord` nor `Note` carries a scale or cue flag — nothing in the model distinguishes a cue-sized note from a full-sized one. |
| Slash notation | no dedicated voice element represents it — a slash is neither a `Chord` nor a `Rest` in the model. |
| Figured bass | no dedicated annotation type carries it — the model has nothing analogous to `Harmony` for a figured-bass numeral. |
| Pedal line style | `Spanner` has no pedal-style payload — `SetPedal` (#64) writes `rawType = "Pedal"` only. |
| Chord-symbol transposition | `SetChordSymbol` (#73) writes `Harmony.name` and nils `rootTpc` / `bassTpc` (and nils them on a file-authored symbol it retypes), so a written symbol carries no transposable root. |
| Tempo text words ("Allegro") | `Tempo` has no text field; `SetTempo.Marking` is the metronome mark alone, and the encoder synthesizes the `<text>` from it. |
| A lane element at a tick no chord starts | tempo / staff text are addressed by the chord or rest they sit on (spec §2.3); a `<location>`-jogged file-authored lane element cannot be removed. |
| A clef MuseScore wrote at the end of a bar | outside any attachment run; `SetClef` on the next bar's first chord inserts a second clef instead of replacing it (`RemoveClef` removes it explicitly). |
| Dynamics on rests | `SetDynamic` requires a chord with notes; MuseScore allows a dynamic on a rest. |
| 4-bar measure-repeat anchor | `SetMeasureRepeat` writes the `%` into the group's first bar; MuseScore anchors it in bar `numMeasures / 2`. Playback searches the whole group, so only the file differs. |
| Cross-bar lengthening in a range | `SetDurationInRange` refuses a lengthening that crosses the bar line (`insufficientRoom`); no tied chain is spelled. |
| Ties on added-interval notes | `AddIntervalToSelection` adds notes without ties even where the source note is tied. |
| Arpeggio stretch, `userLen1`, wavy chord line | `Arpeggio.timeStretch` / `userLen1` and `ChordLine.isWavy` are on the model and round-trip, but the v1 wire keeps intents scalar and carries none of them; reachable only by building the command (or a `ReplaceVoiceElement`) directly. |
| A second chord line on one chord | `SetChordLine` writes one line per chord and drops a second one a file may legitimately carry. |
| Removing one slur of a chord that carries two | `RemoveSpanner` takes every entry of `Chord.spanners` at the target; a caller that means only the inner or the outer one writes the `ReplaceVoiceElement` directly. |

---

## History

The queue in §B was worked in this order: tuplets, measures and parts,
signatures, rehearsal marks, drum entry (M1–M6), then the parity
project's seven groups — structural, range, marks, note / chord,
visibility, spanners, harmony — one merge each, 2026-09-02 …
2026-09-03.

### What proved it, at the close (2026-09-03)

Stated as measurement, so a later reader can tell evidence from
intention:

- **Swift, the whole package:** 4100 tests in 698 suites pass. Two
  known issues are unrelated to editing and predate the project (a PDF
  text-glyph bbox case, and a hairpin MIDI velocity-ramp follow-up).
- **The parity replay chain is frozen** at 92 steps: `goldens.txt` is
  93 lines, `editReplay-parity/` holds 87 `step-*.bin` files (92 steps
  less the 5 undos), and 61 of the 93 recorded fingerprints are
  distinct against a floor of 57. It is never extended or re-recorded
  again; a new command opens a new chain.
- **Browser (WebAssembly):** 131 of 131 vitest tests pass across 12
  files, 0 skipped. `edit.test.ts` drives BOTH chains — the original
  and the 92-step parity one — through the wasm facade, asserting each
  step's acceptance as well as the fingerprint. **Build the wasm binary
  before trusting that suite**: with no binary in the tree the edit
  tests SKIP and the run is still green, which is a suite that verified
  nothing.
- **MSCX save idempotency:** every score of a 669-file external corpus
  that the reader accepts — 668 of them — encodes byte-identically on
  pass 1 and pass 2, 0 differing. (The 669th is a MuseScore 1.x file,
  outside this reader's stated scope.) A permanent version of this
  gate, always-on over the in-tree fixtures and opt-in over an external
  corpus, lands separately.
- **Not run, at the close:** the Kotlin `EditSessionReplayParityTest`. It
  is device-only instrumentation, and the chain had grown to 92 steps
  with 87 step assets that test had never consumed. Running it on a
  device was the one outstanding verification for this project.

### Run, 2026-09-04

It passes. `:SheetMusicAndroid:connectedDebugAndroidTest` on an API 35
arm64 emulator: 5 tests, 0 failures, both `replayMatchesHostGoldens`
methods among them — the original chain and the 92-step parity one, each
relayed step by step from Kotlin across JNI into a second,
separately-linked image of the engine, with equal fingerprints at every
step. That is the claim the whole Android editing design rests on, and it
now has a result rather than an intention.

The instrumented suite is also wired into CI (`.github/workflows/android-audio.yml`),
so it stays run rather than being re-discovered as unrun later.
