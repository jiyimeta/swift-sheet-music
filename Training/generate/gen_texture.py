"""Texture generator (spec §6.1.2): engraving-realistic musical fabric —
volume and context, complementing `gen_coverage`'s rare-class enumeration.
"Musically shallow but engraving-realistic" is sufficient by design (the
detector learns ink, not music): seeded random-walk melodies, chord
stacks, beamed runs, tuplets, grace notes, multi-voice measures,
grand-staff / multi-staff parts, drum staves with X-heads, and English
lyric syllables. All randomness flows from one seed through per-source
`numpy.random.Generator`s, so a batch is deterministic and each source is
independently reproducible from its own child seed.

Reuses `gen_coverage`'s `PartSpec` / `mscx_document` / `chord` / `rest` /
`time_sig` helpers rather than building a second MSCX emitter; new shapes
(Tuplet, grace chords, a second `<voice>`, drum `<head>` override) are
built as thin string-level extensions on top of `chord()`'s output,
cross-checked against this repo's own MSCX encoder/decoder and against
`gen_coverage.py`'s already-verified conventions:

- `<Tuplet>` is a flat voice-stream sibling (not a wrapper): a
  `<Tuplet><normalNotes>/<actualNotes>/<baseNote></Tuplet>` marker,
  then the unscaled-duration `<Chord>` members, then `<endTuplet/>`.
  Confirmed against `MSCXDecoder+Voice.swift` (`case "Tuplet"` /
  `case "endTuplet"`, stack-based, reads only `normalNotes`/
  `actualNotes`) and `MSCXEncoder+Tuplet.swift` (`<baseNote>` is
  REQUIRED — MuseScore 3 leaves `_baseLen` invalid without it and
  SIGFPEs on open). A real MuseScore file also writes a `<Number>`
  child for the visible "3"/"5"/"7". These `.mscx` sources are rendered
  to PDF by real MuseScore Studio (`mscore` CLI — see
  `docs/superpowers/specs/2026-08-06-omr-raster-foundation-design.md`
  §6, "source .mscx → mscore CLI → PDF"), not by this package's own
  renderer, so what matters is what `mscore` itself does with an absent
  `<Number>` — checked read-only (never vendored/copied) against a
  local MuseScore checkout: `engraving/rw/read400/tread.cpp`'s
  `TRead::read(Tuplet*, …)` initializes its local `Text* number` to
  `nullptr` and only constructs one inside the `tag == "Number"`
  branch, so an absent `<Number>` leaves `Tuplet::number()` null after
  load. `engraving/rendering/score/tupletlayout.cpp`'s
  `TupletLayout::createNumber` (called during layout, not read) then
  lazily creates that `Text` from `item->ratio().numerator()` — the
  `actualNotes` value — whenever `numberType() != NO_TEXT`, and
  `TupletNumberType`'s in-class default (`engraving/dom/tuplet.h`) is
  `SHOW_NUMBER`. So `mscore` draws the correct bracket numeral from the
  ratio alone; `<Number>` is omitted here as confirmed-unnecessary, not
  invented.
- A grace note is a *separate* `<Chord>` immediately before the note it
  decorates, carrying a bare `<acciaccatura/>` child anywhere among its
  children (order-independent — `Chord.graceType(in:)` just scans for a
  known grace tag). Confirmed against `MSCXDecoder+Voice.swift`'s
  `case "Chord": if let graceType = Chord.graceType(in: child)` branch:
  such a chord is pulled out of the ordinary element stream into
  `pendingGracesBefore` and explicitly does NOT advance the measure
  cursor (`continue`, skipping `cursor += chord.duration.asFraction`).
  A grace note therefore must NOT be charged against this generator's
  own tick budget — charging it would leave the enclosing bar short by
  the grace's nominal duration once MuseScore re-derives bar length
  from chord durations. (An earlier draft of this generator turned the
  *main* note of a walk step into the grace note and still added its
  duration to the tick budget; that under-fills the bar by exactly the
  grace's duration once decoded and was corrected here.)
- A second `<voice>` is a `<Measure>`-level sibling of the first, in
  any order. Confirmed against `MSCXDecoder+Measure.swift`:
  `node.all("voice")` collects every `<voice>` child positionally, with
  no index attribute involved.
- `<Lyrics>` is a `<Chord>`-level sibling emitted between
  `<durationType>` and `<Note>`. Confirmed against
  `MSCXEncoder+Chord.swift` ("Lyrics sit between durationType and the
  first <Note>") and read back via `node.all("Lyrics")` in
  `MSCXDecoder+Chord.swift` (order-independent on decode).
- A drum staff is `<StaffType group="percussion">` (Staff.group is a
  verbatim pass-through of the XML attribute, confirmed in
  `MSCXDecoder+Staff.swift`); X-shaped noteheads are a per-`<Note>`
  `<head>cross</head>` override, confirmed against
  `MSCXDecoder+Note.swift`'s `decodeHeadType` (`"cross"` is a known MS3/
  MS4 token) and `MSCXEncoder+Note.swift` (`<head>` sits after
  `<pitch>`/`<tpc>`, order-independent on decode). Percussion `tpc` is
  spelling metadata with no percussion meaning, so it is left at a
  fixed placeholder value rather than derived from the drum pitch.

Pitch generation is intentionally confined to the C-major diatonic
pitch-class set {0,2,4,5,7,9,11} (`_MAJOR`): `_tpc_for` only has table
entries for those seven classes, matching `gen_coverage.py`'s own
`chord(60, 14, …)`-style natural-note usage. A raw chromatic random
walk (±1/±2 semitones per step) would eventually land on a non-diatonic
pitch class and KeyError; walking in scale-degree steps over
`_DIATONIC_PITCHES` instead keeps every generated pitch class in that
set by construction.
"""

import numpy as np

from generate.mscx_builder import (TPC_BY_PITCH_CLASS, PartSpec, chord,
                                   mscx_document, rest, time_sig)

_MAJOR = [0, 2, 4, 5, 7, 9, 11]
#: Kept as a module-local alias: the table is shared with the coverage
#: generator (`mscx_builder.TPC_BY_PITCH_CLASS`) so the two cannot spell
#: the same pitch differently.
_TPC_BY_PITCH_CLASS = TPC_BY_PITCH_CLASS
_SYLLABLES = ["la", "sun", "day", "light", "moon", "riv", "er", "sky",
              "gold", "en", "morn", "ing", "wind", "song", "heart", "home"]
_DUR_TICKS = {"whole": 16, "half": 8, "quarter": 4, "eighth": 2, "16th": 1}
_STEP_DURATIONS = ["quarter", "eighth", "16th", "half"]

# Every C-major diatonic pitch across a generous MIDI-ish range, so a
# scale-degree random walk starting near any of this module's staff
# bases (all diatonic — see `texture_sources`) stays comfortably inside
# the list no matter how far `np.clip` lets it wander.
_DIATONIC_PITCHES = sorted(
    12 * octave + pitch_class
    for octave in range(-2, 12)
    for pitch_class in _MAJOR
)

# (normalNotes, actualNotes, baseNote) — each fills exactly one quarter
# note (4 ticks): a triplet of eighths, a quintuplet of 16ths, a
# septuplet of 32nds. Spans the "3:2 … 7:8" range called for in the task
# brief with the conventional written-note choice for each ratio.
_TUPLET_KINDS = [(2, 3, "eighth"), (4, 5, "16th"), (8, 7, "32nd")]

# General MIDI drum pitches used only as staff-line variety; percussion
# notation has no Western pitch spelling, so `tpc` stays fixed (see
# module docstring).
_DRUM_PITCHES = [36, 38, 42, 45, 49]

# Deterministic per-source "kind" cycle (instead of a random draw) so a
# batch of >= 5 sources is guaranteed to exercise every kind — and thus
# every feature that depends on a kind (lyrics, drums, multi-part
# scores) — regardless of seed. Content within each source (pitches,
# tuplets, grace notes, rests, lyric choice, drum pattern, ties) is
# still fully seed-derived.
_KINDS = ["solo", "grand", "band", "vocal", "drums"]


def _tpc_for(pitch: int) -> int:
    """Tonal-pitch-class for a pitch drawn from `_DIATONIC_PITCHES` (or
    any other pitch whose class is one of the seven natural notes)."""
    return _TPC_BY_PITCH_CLASS[pitch % 12]


def _lyrics(syllable: str) -> str:
    return (
        "            <Lyrics>\n"
        f"              <text>{syllable}</text>\n"
        "            </Lyrics>"
    )


def _chord_with_extras(pitch: int, duration: str, lyric: str | None = None,
                        stack: int = 0) -> str:
    """A `chord()` call plus an optional lyric syllable and `stack`
    extra notes above `pitch` (diatonic thirds — two `_DIATONIC_PITCHES`
    steps apart — so every added note stays inside `_tpc_for`'s table)."""
    body = chord(pitch, _tpc_for(pitch), duration=duration)
    if lyric:
        body = body.replace(
            "            <Note>", _lyrics(lyric) + "\n            <Note>", 1,
        )
    if stack:
        base_idx = _DIATONIC_PITCHES.index(pitch)
        for k in range(stack):
            extra_idx = min(base_idx + 2 * (k + 1), len(_DIATONIC_PITCHES) - 1)
            extra = _DIATONIC_PITCHES[extra_idx]
            body = body.replace(
                "          </Chord>",
                "            <Note>\n"
                f"              <pitch>{extra}</pitch>\n"
                f"              <tpc>{_tpc_for(extra)}</tpc>\n"
                "            </Note>\n          </Chord>",
                1,
            )
    return body


def _grace_chord(pitch: int) -> str:
    """A standalone acciaccatura `<Chord>` (written as a 16th) to place
    immediately before an ordinary chord. Never charged against the
    caller's tick budget — see module docstring."""
    body = chord(pitch, _tpc_for(pitch), duration="16th")
    return body.replace("<Chord>\n", "<Chord>\n            <acciaccatura/>\n", 1)


def _tuplet(rng, center_idx: int) -> str:
    """A tuplet (3:2 eighths, 5:4 16ths, or 7:8 32nds — each filling
    exactly one quarter note) with member pitches wandering diatonically
    near `center_idx`."""
    normal, actual, base_dur = _TUPLET_KINDS[int(rng.integers(0, len(_TUPLET_KINDS)))]
    idx = center_idx
    notes = []
    for _ in range(actual):
        step = int(rng.integers(-1, 2))
        idx = int(np.clip(idx + step, center_idx - 2, center_idx + 2))
        pitch = _DIATONIC_PITCHES[idx]
        notes.append(chord(pitch, _tpc_for(pitch), duration=base_dur))
    return (
        "          <Tuplet>\n"
        f"            <normalNotes>{normal}</normalNotes>\n"
        f"            <actualNotes>{actual}</actualNotes>\n"
        f"            <baseNote>{base_dur}</baseNote>\n"
        "          </Tuplet>\n" + "\n".join(notes) + "\n          <endTuplet/>"
    )


def _walk_measure(rng, base: int, with_lyrics: bool, first: bool) -> str:
    """One 4/4 measure (16 ticks of a 16th note each): a diatonic
    random-walk melody, with occasional tuplets, grace notes, rests,
    lyric syllables, and stacked extra notes. `base` must be a diatonic
    pitch (all staff bases in `texture_sources` are)."""
    parts = [time_sig(4, 4)] if first else []
    start_idx = _DIATONIC_PITCHES.index(base)
    idx = start_idx
    ticks = 0
    while ticks < 16:
        if ticks == 0 and rng.random() < 0.2:
            parts.append(_tuplet(rng, idx))
            ticks += 4
            continue
        dur = str(rng.choice(_STEP_DURATIONS))
        remaining = 16 - ticks
        if _DUR_TICKS[dur] > remaining:
            dur = "quarter" if remaining >= 4 else "eighth" if remaining >= 2 else "16th"
        step = int(rng.integers(-2, 3))
        idx = int(np.clip(idx + step, start_idx - 7, start_idx + 7))
        pitch = _DIATONIC_PITCHES[idx]
        if rng.random() < 0.1:
            parts.append(rest(dur))
        else:
            if rng.random() < 0.12:
                parts.append(_grace_chord(pitch))
            lyric = (
                str(rng.choice(_SYLLABLES))
                if with_lyrics and rng.random() < 0.7 else None
            )
            stack = int(rng.integers(1, 3)) if rng.random() < 0.2 else 0
            parts.append(_chord_with_extras(pitch, dur, lyric=lyric, stack=stack))
        ticks += _DUR_TICKS[dur]
    return "\n".join(parts)


def _drum_note(pitch: int, duration: str) -> str:
    body = chord(pitch, 14, duration=duration)
    return body.replace("</tpc>", "</tpc>\n              <head>cross</head>", 1)


def _drum_measure(rng, first: bool) -> str:
    """A one-bar drum pattern: eighth-note hits across a small kit,
    occasionally opening with a half-note crash, all X-notehead."""
    parts = [time_sig(4, 4)] if first else []
    ticks = 0
    while ticks < 16:
        dur = "half" if ticks == 0 and rng.random() < 0.15 else "eighth"
        pitch = int(_DRUM_PITCHES[int(rng.integers(0, len(_DRUM_PITCHES)))])
        parts.append(_drum_note(pitch, dur))
        ticks += _DUR_TICKS[dur]
    return "\n".join(parts)


def texture_sources(seed: int, count: int) -> list[tuple[str, str]]:
    """`count` independently-reproducible multi-part `.mscx` sources
    named `tex_0000` … `tex_{count-1:04d}`. Every source's content is
    driven by its own child seed derived from `seed`, so the batch is
    deterministic and each source can be regenerated in isolation given
    its index. See module docstring for the feature/shape rationale."""
    root_rng = np.random.default_rng(seed)
    child_seeds = root_rng.integers(0, 2**32, size=count)
    sources: list[tuple[str, str]] = []
    for i in range(count):
        rng = np.random.default_rng(int(child_seeds[i]))
        n_measures = int(rng.integers(8, 17))
        kind = _KINDS[i % len(_KINDS)]
        parts: list[PartSpec] = []
        if kind in ("solo", "vocal"):
            measures = [_walk_measure(rng, 67, kind == "vocal", m == 0)
                        for m in range(n_measures)]
            parts.append(PartSpec(name="Voice", measures=measures))
        elif kind == "grand":
            treble = [_walk_measure(rng, 72, False, m == 0) for m in range(n_measures)]
            bass = [_walk_measure(rng, 50, False, m == 0) for m in range(n_measures)]
            parts.append(PartSpec(name="Piano RH", measures=treble))
            parts.append(PartSpec(name="Piano LH", clef="F", measures=bass))
        elif kind == "band":
            for name, base, clef in [("Flute", 79, "G"), ("Alto", 67, "G"),
                                      ("Tenor", 60, "G8vb"), ("Bass", 48, "F")]:
                parts.append(PartSpec(
                    name=name, clef=clef,
                    measures=[_walk_measure(rng, base, False, m == 0)
                              for m in range(n_measures)]))
        elif kind == "drums":
            parts.append(PartSpec(
                name="Drums", clef="PERC",
                measures=[_drum_measure(rng, m == 0) for m in range(n_measures)]))
        text = mscx_document(parts)
        if kind == "drums":
            # Unscoped replace: correct only because "drums" always
            # produces exactly one PartSpec / one <StaffType>, so there
            # is exactly one 'group="pitched"' in `text` to flip. If a
            # future kind ever mixes a drum staff with pitched staves
            # in the same document, this would need to target the
            # specific staff block instead of a global replace.
            text = text.replace('group="pitched"', 'group="percussion"')
        # Multi-voice: append a second voice to the first measure of some
        # multi-part sources. Two tied-together half notes exactly fill
        # a 4/4 bar, so the injected voice is itself well-formed.
        if kind in ("grand", "band") and rng.random() < 0.5:
            second = ("\n        <voice>\n"
                      + "\n".join(chord(55, 15, duration="half") for _ in range(2))
                      + "\n        </voice>")
            text = text.replace("</voice>", "</voice>" + second, 1)
        sources.append((f"tex_{i:04d}", text))
    return sources
