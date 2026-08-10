"""Coverage-score generator (spec §6.1.1): .mscx sources that exercise
rare detector classes so per-class floors (gate P3c-G3) are reachable.
MS3 (3.02) schema, written by our own template code. Deterministic: all
variation derives from the seed via numpy Generators.

The XML shapes live in `mscx_builder`, whose module docstring records
where each one was cross-checked. This file is only about WHAT to draw
and HOW MUCH of it.

## Sizing -- why the families look repetitive

The first real pilot (2026-08-08, 1888 renders) passed the per-class
floor for 16 of 64 classes. The 48 misses were not all zeros: coverage
families drew each rare class ONCE or twice per render (16 accidentals,
16 segno, 32 octave clefs, 24 timeSigCommon in the whole dataset), which
is three orders of magnitude short of a 1000-instance floor. Adding the
missing classes without also fixing the density would have swapped 17
zeros for 17 sixteens.

So every family below is sized against `PER_RENDER_TARGET`, and the
arithmetic is written out at each family. A source is rendered once per
face per `--per-face` variant, so at the runbook's `--engines ms4
--per-face 2` (8 faces) that is `RENDERS_PER_SOURCE` renders carrying
identical content.

Density is bought as cheaply as the notation allows, because pages cost
generation time and disk:

- clefs come from mid-score `<Clef>` CHANGES (four per bar), not from
  one clef per system;
- time-signature digits come from a meter change in every bar, with the
  bar filled by a single measure rest;
- the brace comes from forced `<LayoutBreak>` systems, so the count is a
  property of the source rather than of the page size each face variant
  draws.

## What this generator still CANNOT reach

Seven of the 64 frozen detector classes are not produced by the vector
front-end that writes the labels, so no amount of generation makes them
appear. Five (`dynamic`, `articulation`, `ornament`, `dalSegno`,
`daCapo`) are drawn here anyway, because the gap is in the classifier's
codepoint table and closing it is what makes this content pay off. Two
are unreachable by construction and are recorded in
`UNREACHABLE_DETECTOR_CLASSES` below.
"""

from dataclasses import dataclass

import numpy as np

from generate import vocabulary
from generate.mscx_builder import (PartSpec, StaffSpec, bar_of_rests, chord,
                                   clef_change, dynamic, end_repeat, fermata,
                                   jump, layout_break, marker, measure_rest,
                                   mscx_document, natural_chord, natural_pitch,
                                   rest, start_repeat, time_sig, tpc_for)

#: Renders each source receives under the runbook's standard invocation
#: (`--engines ms4 --per-face 2`): 8 ms4 faces x 2 style variants. Read
#: out of `style_matrix.FACES` by `test_gen_coverage`, so a face added or
#: removed there fails a test here instead of quietly halving coverage.
RENDERS_PER_SOURCE = 16

#: `finalize --class-floor`'s default. Mirrored here so the per-family
#: arithmetic is checkable without running the gate.
CLASS_FLOOR = 1000

#: Instances of a rare class one render must carry.
#: ceil(1000/16) = 63; 70 leaves room for a face whose page size costs a
#: system, and for the handful of classes that arrive one-per-bar.
PER_RENDER_TARGET = 70

#: Detector classes no generator can produce, with the reason. Declared
#: next to the frozen class list itself (`vocabulary.UNREACHABLE`) rather
#: than here, because the gate that honours the exemption reads it from
#: there and the two must not be able to disagree. Re-exported so the
#: coverage families and their tests can name it without importing the
#: vocabulary module for one symbol.
UNREACHABLE_DETECTOR_CLASSES = vocabulary.UNREACHABLE

#: Sources that deliberately use a `<durationType>` this package's own
#: `NoteDuration(mscxName:)` cannot decode, and therefore cannot serve
#: as score-level ground truth (`MSCXDecoder+Chord.swift` throws
#: `malformedScore`). Kept because the glyph they draw is in the frozen
#: class vocabulary and the seam-level labels come from the PDF, not
#: from the source. Each one is isolated into a source of its own so the
#: loss never spreads to unrelated content -- see `cov_doublewhole`.
#: `validate_mscx`'s generator regression test exempts exactly these,
#: and only for `unknown-duration` problems: a measure-length error in
#: one still fails.
UNDECODABLE_DURATION_SOURCES = frozenset({"cov_doublewhole"})

#: MuseScore `ClefType` tokens for `<defaultClef>` and for a mid-score
#: `<Clef><concertClefType>`.
#:
#: "C3" (alto), NOT a bare "C". MuseScore has no such token -- the C
#: clefs are named by the staff line they sit on, `C1`…`C5` -- and an
#: unrecognized token is resolved SILENTLY to the treble default.
#: Measured on the first pilot: `cov_clef_c`'s renders came back carrying
#: `clefG`, and `clefC` finished the run with 0 instances while every
#: other clef class had its expected count. This repo's own
#: `Sources/SheetMusicCore/Score/NotatedClef.swift:42,67` spells the pair
#: `"C3"` / `"C4"` (alto / tenor); there is no bare "C" there either.
_CLEFS = ["G", "G8va", "G8vb", "G15ma", "G15mb",
          "F", "F8va", "F8vb", "F15ma", "F15mb", "C3", "PERC"]

#: Clefs a mid-score `<Clef>` change can actually engrave on a pitched
#: staff. `PERC` cannot, and is dropped SILENTLY -- measured: a probe
#: rotating all twelve through `cov_clef_changes` produced 72 of every
#: other clef class and 2 `clefPercussion` (its `<defaultClef>` source's
#: system starts, a different code path).
#:
#: Upstream says why. A clef whose `ClefInfo::staffGroup` disagrees with
#: the staff's group is hidden outright at any tick past 0 --
#: `rendering/score/tlayout.cpp:1657-1674` sets `show = false`,
#: `symId = noSym`, and logs a debug line no headless export ever shows.
#: The staff group here is STANDARD because the part has no drumset
#: (`tlayout.cpp:1652-1654`), and the percussion clef's is PERCUSSION.
#: At tick 0 the same branch takes its `else`, which is why
#: `<defaultClef>PERC` works and a change does not.
#:
#: So `clefPercussion` volume comes from system starts instead -- see
#: `_clef_family`, which gives that one source forced line breaks.
_CLEF_CHANGE_TOKENS = [clef for clef in _CLEFS if clef != "PERC"]

#: Source id whose clef arrives once per system rather than once per
#: `<Clef>` element, for the reason above.
_SYSTEM_START_CLEF_SOURCE = "cov_clef_perc"

#: One rotation covers every time-signature digit plus the two symbol
#: meters. `(n, d, subtype)`; subtype 1 = common "C", 2 = cut "cut-C".
#: Digit yield per rotation: 0x1, 1x2, 2x2, 3x1, 4x4, 5x1, 6x1, 7x1,
#: 8x3, 9x1 -- so the scarcest digit arrives once per rotation and
#: `PER_RENDER_TARGET` rotations satisfy all ten at once.
#:
#: Consecutive entries must DIFFER or MuseScore engraves nothing: a
#: time signature is drawn on change. The wrap-around pair (last -> first
#: of the next rotation) counts, which is why (2,2,cut) is followed by
#: (2,4), not by another 2/2.
_METER_ROTATION = [
    (2, 4, 0), (3, 4, 0), (5, 4, 0), (6, 8, 0), (7, 8, 0),
    (9, 8, 0), (10, 4, 0), (12, 8, 0), (4, 4, 1), (2, 2, 2),
]

#: SymId tokens for `<Articulation>`. Both lists are `<Articulation>`
#: children of `<Chord>` in the MS3 schema -- MuseScore 3 had no separate
#: `<Ornament>` element, and MuseScore 4 migrates these on read. Every
#: name below was verified present in MuseScore's own
#: `fonts/smufl/glyphnames.json` (an unknown SymId is dropped silently,
#: the same failure mode as the clef tokens above).
_ARTICULATIONS = ["articAccentAbove", "articStaccatoAbove",
                  "articTenutoAbove", "articMarcatoAbove",
                  "articStaccatissimoAbove", "articAccentBelow",
                  "articStaccatoBelow", "articTenutoBelow"]
_ORNAMENTS = ["ornamentTrill", "ornamentTurn", "ornamentTurnInverted",
              "ornamentMordent", "ornamentShortTrill",
              "ornamentTremblement"]

#: `<Dynamic><subtype>`. Multi-letter subtypes draw one glyph per letter,
#: so the class count runs ahead of the element count -- fine, the floor
#: is a floor.
_DYNAMICS = ["p", "mp", "mf", "f", "ff", "pp", "sf", "fp"]


@dataclass(frozen=True)
class _Bar:
    """A measure body plus its Measure-level sibling XML."""
    body: str
    sibling: str = ""


def _single_staff(name: str, bars: list[_Bar], clef: str = "G") -> str:
    return mscx_document([PartSpec(
        name=name, clef=clef,
        measures=[b.body for b in bars],
        measure_siblings=[b.sibling for b in bars],
    )])


def _clef_family(rng) -> list[tuple[str, str]]:
    """One source per clef, under a `<defaultClef>`. The only family that
    exercises that read path -- which is where the silent clef-token
    fallback documented on `_CLEFS` bit -- so it is kept even though a
    system-start clef is a low-yield way to draw one.

    The percussion source is the exception and is sized for volume:
    `PERC` is the one clef a mid-score change cannot engrave (see
    `_CLEF_CHANGE_TOKENS`), so `cov_clef_changes` cannot carry it and
    this source has to. `<LayoutBreak>` every second bar pins the system
    count, and a clef is engraved at every system start.
    """
    out = []
    for clef in _CLEFS:
        base = 60 if clef.startswith("G") else 48 if clef.startswith("F") else 55
        source_id = f"cov_clef_{clef.lower()}"
        systems = (PER_RENDER_TARGET
                   if source_id == _SYSTEM_START_CLEF_SOURCE else 4)
        bars = []
        for i in range(systems * 2):
            pitches = base + rng.integers(-5, 6, size=4)
            body = [time_sig(4, 4)] if i == 0 else []
            body += [natural_chord(int(p)) for p in pitches]
            bars.append(_Bar("\n".join(body),
                             layout_break() if i % 2 == 1 else ""))
        out.append((source_id, _single_staff(f"Clef {clef}", bars, clef=clef)))
    return out


def _clef_changes_source(rng) -> tuple[str, str]:
    """Volume for all twelve clef classes: four `<Clef>` changes per bar,
    rotating so no change is a no-op.

    11 clefs x PER_RENDER_TARGET clef glyphs, 4 per bar. `PERC` is not in
    the rotation because a mid-score change to it is hidden outright on a
    pitched staff -- see `_CLEF_CHANGE_TOKENS`.

    The rotation starts one past the staff default (`G`) so the very
    first change is not dropped as "already that clef".
    """
    tokens = _CLEF_CHANGE_TOKENS
    bars = []
    step = 0
    total = len(tokens) * PER_RENDER_TARGET
    while step < total:
        body = [time_sig(4, 4)] if not bars else []
        for _ in range(4):
            body.append(clef_change(tokens[(step + 1) % len(tokens)]))
            body.append(natural_chord(int(60 + rng.integers(-4, 5))))
            step += 1
        bars.append(_Bar("\n".join(body)))
    return "cov_clef_changes", _single_staff("Clef changes", bars)


def _accidentals_source() -> tuple[str, str]:
    """Five accidental classes, PER_RENDER_TARGET each.

    THE `<tpc>` HAS TO REQUIRE THE ACCIDENTAL. MuseScore does not draw an
    `<Accidental>` just because the XML carries one -- it engraves what
    the note's spelling needs and drops a redundant or contradictory mark
    SILENTLY. Measured on the first pilot: this family shipped
    `accidentalDoubleSharp` on tpc 16 (a plain D) and `accidentalNatural`
    on tpc 14 (a plain C in C major), and both finished the run with 0
    instances while sharp / flat / double-flat -- whose tpcs did need a
    mark -- came through fine.

    tpc is the line of fifths with C = 14, so C# = 21, C## = 28, Db = 9,
    Dbb = 2. A natural is only required to CANCEL an earlier accidental
    IN THE SAME BAR, so each bar alters its pitch class first and asks
    for the natural afterwards.

    Two bars yield one each of sharp / doubleSharp / flat / doubleFlat
    and four naturals, so PER_RENDER_TARGET pairs = 140 bars.
    """
    bars = []
    for i in range(PER_RENDER_TARGET):
        first = [time_sig(4, 4)] if i == 0 else []
        bars.append(_Bar("\n".join(first + [
            chord(61, 21, accidental="accidentalSharp"),        # C#
            chord(60, 14, accidental="accidentalNatural"),      # C natural
            chord(62, 28, accidental="accidentalDoubleSharp"),  # C##
            chord(60, 14, accidental="accidentalNatural"),      # C natural
        ])))
        bars.append(_Bar("\n".join([
            chord(61, 9, accidental="accidentalFlat"),          # Db
            chord(62, 16, accidental="accidentalNatural"),      # D natural
            chord(60, 2, accidental="accidentalDoubleFlat"),    # Dbb
            chord(62, 16, accidental="accidentalNatural"),      # D natural
        ])))
    return "cov_accidentals", _single_staff("Accidentals", bars)


def _dots_source() -> tuple[str, str]:
    """`augmentationDot`, PER_RENDER_TARGET+ per render.

    A double dot is TWO dot glyphs, so the two bar shapes below yield two
    each: (dotted quarter + eighth) x2 = 3/8+1/8+3/8+1/8, and
    (double-dotted half + eighth) = 7/8+1/8.
    """
    bars = []
    singles = (PER_RENDER_TARGET * 2) // 3 // 2   # 2 dots per bar
    doubles = PER_RENDER_TARGET // 3 // 2 + 1     # 2 dots per bar
    for i in range(singles):
        first = [time_sig(4, 4)] if i == 0 else []
        bars.append(_Bar("\n".join(first + [
            chord(60, 14, duration="quarter", dots=1),
            chord(62, 16, duration="eighth"),
            chord(64, 18, duration="quarter", dots=1),
            chord(65, 13, duration="eighth"),
        ])))
    for _ in range(doubles):
        bars.append(_Bar("\n".join([
            chord(60, 14, duration="half", dots=2),
            chord(62, 16, duration="eighth"),
        ])))
    return "cov_dots", _single_staff("Dots", bars)


def _durations_source() -> tuple[str, str]:
    """Every rest shape, and the short durations, in one place.

    EVERY BAR SUMS EXACTLY TO ITS METER, and `validate_mscx` enforces it.
    An overfull bar is not a cosmetic defect: MuseScore 4 aborts during
    layout and writes no PDF, so the source is lost in every face at once
    (measured -- a 4/4 bar holding 6 quarters cost all 8 faces of the
    first pilot run). The 64th/32nd bar below is split from its half-rest
    tail for exactly that reason.
    """
    bars = [
        _Bar("\n".join([time_sig(4, 4), chord(60, 14, duration="whole")])),
        _Bar("\n".join([chord(60, 14, duration="half", dots=1),
                        chord(62, 16, duration="quarter")])),
        _Bar("\n".join([chord(60, 14, duration="quarter", dots=2),
                        chord(62, 16, duration="16th"),
                        rest("quarter"), rest("quarter")])),
        _Bar("\n".join([chord(60, 14, duration="64th")] * 8      # 1/2
                       + [rest("64th")] * 8                      # 1/2
                       + [chord(62, 16, duration="32nd")] * 4    # 1/2
                       + [rest("32nd")] * 4                      # 1/2
                       + [rest("eighth"), rest("16th"), rest("16th"),
                          rest("quarter")])),                    # 2/4 -> 4/4
        _Bar("\n".join([rest("half"), rest("half")])),
        _Bar("\n".join([rest("whole")])),
    ]
    return "cov_durations", _single_staff("Durations", bars)


def _wholes_source() -> tuple[str, str]:
    """`noteheadWhole` and `restWhole`, PER_RENDER_TARGET each.

    The two alternate rather than running in blocks: MuseScore merges
    CONSECUTIVE empty bars into a multimeasure rest when that style is
    on, which would collapse a run of whole rests into one glyph and a
    number. Interleaving makes the count independent of the style each
    face variant draws.
    """
    bars = []
    for i in range(PER_RENDER_TARGET):
        first = [time_sig(4, 4)] if i == 0 else []
        bars.append(_Bar("\n".join(first + [chord(60, 14, duration="whole")])))
        bars.append(_Bar(rest("whole")))
    return "cov_wholes", _single_staff("Wholes", bars)


def _doublewhole_source() -> tuple[str, str]:
    """The double whole (breve), isolated into its own source.

    `noteheadDoubleWhole` is in the frozen class vocabulary, so the
    dataset has to draw one -- but `breve` is NOT in this package's
    `NoteDuration(mscxName:)`, so `MSCXDecoder+Chord.swift` throws
    `malformedScore` on it and `source.mscx` cannot serve as score-level
    ground truth. Keeping it in `cov_durations` would have cost the
    score-level signal of every other duration in that file; here the
    loss is confined to one small source, which prints a single
    `FAIL-THREW` line under OMR_SCORE_EVAL. The seam-level labels, which
    is where the class is actually needed, are read from the PDF and are
    unaffected.
    """
    bars = [_Bar("\n".join(
        ([time_sig(4, 2)] if i == 0 else [])
        + [chord(60, 14, duration="breve")]))
        for i in range(PER_RENDER_TARGET)]
    return "cov_doublewhole", _single_staff("Double whole", bars)


def _noteheads_x_source() -> tuple[str, str]:
    """`noteheadXWhole` / `noteheadXHalf`, PER_RENDER_TARGET each.

    `<head>cross</head>` is the `NoteHead::Group` token
    (`MSCXDecoder+Note.swift:151-188` normalizes it); the group picks the
    X glyph and the DURATION picks which of the three. The black X head
    arrives in bulk from the percussion textures already, so this source
    only has to carry the two that do not.
    """
    bars = []
    for i in range(PER_RENDER_TARGET):
        first = [time_sig(4, 4)] if i == 0 else []
        bars.append(_Bar("\n".join(
            first + [chord(60, 14, duration="whole", head="cross")])))
    for _ in range(PER_RENDER_TARGET // 2):
        bars.append(_Bar("\n".join([
            chord(60, 14, duration="half", head="cross"),
            chord(64, 18, duration="half", head="cross"),
        ])))
    return "cov_noteheads_x", _single_staff("X noteheads", bars)


def _flags_source() -> tuple[str, str]:
    """`flag32ndUp/Down`, `flag64thUp/Down` -- and, free of charge, the
    `rest32nd` / `rest64th` that pad them.

    A 32nd or 64th note only draws a FLAG when it is not beamed, and the
    dataset's beamed textures are why those four classes finished the
    first pilot at zero. Two independent guards, because either alone is
    a silent failure: every short note is separated from the next by a
    rest of its own length (MuseScore does not beam across a rest with
    the default style), and each chord carries
    `<BeamMode>no</BeamMode>`.

    Stem direction is forced rather than inferred from pitch, because the
    up/down flag pair is two detector classes and "which side of the
    middle line is this note on" is exactly the kind of implicit
    assumption this project keeps getting burned by.

    16 notes per 4/4 bar of 32nds (16 x (1/32 + 1/32) = 1), 32 per bar of
    64ths. Five bars per stem direction for the 32nds and three for the
    64ths clears PER_RENDER_TARGET in both.
    """
    bars = []
    first = True
    for duration, per_bar, bars_per_side in (("32nd", 16, 5), ("64th", 32, 3)):
        for stem in ("up", "down"):
            for _ in range(bars_per_side):
                body = [time_sig(4, 4)] if first else []
                first = False
                for i in range(per_bar):
                    base = 60 if stem == "up" else 76
                    body.append(natural_chord(base + 2 * (i % 3),
                                              duration=duration,
                                              stem=stem, no_beam=True))
                    body.append(rest(duration))
                bars.append(_Bar("\n".join(body)))
    return "cov_flags", _single_staff("Flags", bars)


def _timesigs_source() -> tuple[str, str]:
    """All ten digits plus `timeSigCommon` / `timeSigCutTime`.

    One meter change per bar, and the bar filled by a single measure
    rest. Filling with real notes instead is what made the first version
    of this family expensive AND wrong: a 12/8 bar of twelve eighths is
    wide, and the earlier `max(2, n // 2)` quarters underfilled the odd
    eighth meters (7/8 got 3/4, 9/8 got 4/4). MuseScore pads a short bar
    SILENTLY, so nothing failed -- the renders just disagreed with the
    ground truth parsed back out of `source.mscx`.

    A measure rest cannot be over- or underfull by definition, is one
    glyph wide, and draws the whole-rest glyph, so this family doubles as
    `restWhole` volume. Multimeasure rests cannot form here because every
    bar changes meter.

    `bar_of_rests` rather than `measure_rest` directly: a bar longer than
    a whole note comes back as `restDoubleWhole`, which has no detector
    class. Measured -- the 10/4 bar of an earlier probe produced 70
    glyphs labelled `unknownE4E2`.
    """
    bars = []
    for _ in range(PER_RENDER_TARGET):
        for n, d, subtype in _METER_ROTATION:
            bars.append(_Bar("\n".join([time_sig(n, d, subtype=subtype),
                                        bar_of_rests(n, d)])))
    return "cov_timesigs", _single_staff("Meters", bars)


def _navigation_source() -> tuple[str, str]:
    """`segno`, `coda`, `dalSegno`, `daCapo`, `fermata`.

    `dalSegno` / `daCapo` are drawn as GLYPHS here (`<sym>` inside the
    Jump's text) rather than as the words "D.S." / "D.C.". Both spellings
    are legitimate MuseScore output, but only the glyph spelling lands in
    the glyph stream the seam labels are read from -- the words go to the
    text stream, which is where `fine` and `toCoda` live permanently (see
    UNREACHABLE_DETECTOR_CLASSES). The last two bars therefore keep the
    plain-text form as well, so the text stream carries a real example of
    each.

    Marker/Jump are Measure-level siblings of `<voice>`, so they travel
    in `measure_siblings`; the fermata stays inside the voice stream.
    """
    bars = []
    for i in range(PER_RENDER_TARGET):
        first = [time_sig(4, 4)] if i == 0 else []
        bars.append(_Bar(
            "\n".join(first + [measure_rest(4, 4)]),
            marker("segno", "segno") + "\n"
            + jump("<sym>dalSegno</sym>", "segno", "end")))
        # Not a typo: MuseScore's own file-string vocabulary is
        # confusingly crossed here -- a plain CODA marker's <label> is
        # "codab" while the string "coda" itself is reserved for TOCODA.
        # See Marker.swift's Kind.defaultLabel doc comment
        # (Sources/SheetMusicCore/Score/Marker.swift) for the mapping
        # table this mirrors.
        bars.append(_Bar(
            measure_rest(4, 4),
            marker("codab", "coda") + "\n"
            + jump("<sym>daCapo</sym>", "start", "end")))
    for _ in range(PER_RENDER_TARGET // 4 + 1):
        bars.append(_Bar("\n".join(
            [fermata(), chord(60, 14), fermata(), chord(62, 16),
             fermata(), chord(64, 18), fermata(), chord(65, 13)])))
    bars.append(_Bar(measure_rest(4, 4), jump("D.C. al Fine", "start", "fine")))
    bars.append(_Bar(measure_rest(4, 4), jump("To Coda", "coda", "end")))
    return "cov_navigation", _single_staff("Navigation", bars)


def _repeats_source() -> tuple[str, str]:
    """`repeatBarlineDots` -- the dots either side of a repeat barline.

    A start-repeat bar and an end-repeat bar per iteration, so each
    iteration engraves two dot groups. The XML count below is a LOWER
    bound on the class count, not an estimate of it: MuseScore draws each
    group as two separate `repeatDot` (U+E044) glyphs rather than one
    `repeatDots` (U+E043), so the render carries twice what this counts.
    """
    bars = []
    for i in range(PER_RENDER_TARGET // 2):
        first = [time_sig(4, 4)] if i == 0 else []
        bars.append(_Bar("\n".join(first + [chord(60, 14) for _ in range(4)]),
                         start_repeat()))
        bars.append(_Bar("\n".join([chord(62, 16) for _ in range(4)]),
                         end_repeat(2)))
    return "cov_repeats", _single_staff("Repeats", bars)


def _grandstaff_source() -> tuple[str, str]:
    """`brace` -- one per braced part per SYSTEM, which is why this is
    the only family whose yield depends on line breaking.

    `<LayoutBreak><subtype>line</subtype></LayoutBreak>` every second bar
    pins the system count, so three braced parts x 24 systems = 72 braces
    in every face variant rather than "however many systems this page
    size happened to produce".

    Page cost is independent of how the parts/systems trade off: the
    product (parts x 2 staves) x systems is the staff-system total, and
    that is what fills pages. Three parts keeps each system a readable
    six staves.
    """
    parts_count, systems, bars_per_system = 3, 24, 2
    total_bars = systems * bars_per_system

    def staff_bars(clef: str, treble: bool) -> tuple[list[str], list[str]]:
        bodies, siblings = [], []
        for i in range(total_bars):
            first = [time_sig(4, 4)] if i == 0 else []
            body = first + ([chord(60, 14), chord(62, 16), chord(64, 18, duration="half")]
                            if treble else [measure_rest(4, 4)])
            bodies.append("\n".join(body))
            siblings.append(layout_break()
                            if (i + 1) % bars_per_system == 0 else "")
        return bodies, siblings

    parts = []
    for p in range(parts_count):
        top_bodies, top_siblings = staff_bars("G", treble=True)
        bottom_bodies, bottom_siblings = staff_bars("F", treble=False)
        parts.append(PartSpec(
            name=f"Grand {p + 1}", clef="G",
            measures=top_bodies, measure_siblings=top_siblings,
            extra_staves=[StaffSpec(clef="F", measures=bottom_bodies,
                                    measure_siblings=bottom_siblings)],
            braced=True,
        ))
    return "cov_grandstaff", mscx_document(parts)


def _dynamics_source() -> tuple[str, str]:
    """`dynamic`. One `<Dynamic>` before each of four chords per bar."""
    bars = []
    for i in range(PER_RENDER_TARGET // 4 + 1):
        first = [time_sig(4, 4)] if i == 0 else []
        body = list(first)
        for j in range(4):
            body.append(dynamic(_DYNAMICS[(i * 4 + j) % len(_DYNAMICS)]))
            body.append(natural_chord(60 + 2 * j))
        bars.append(_Bar("\n".join(body)))
    return "cov_dynamics", _single_staff("Dynamics", bars)


def _articulation_source(source_id: str, name: str,
                         symbols: list[str]) -> tuple[str, str]:
    """`articulation` / `ornament`. Both are `<Articulation>` children of
    `<Chord>` in the MS3 schema; only the SymId differs."""
    bars = []
    for i in range(PER_RENDER_TARGET // 4 + 1):
        first = [time_sig(4, 4)] if i == 0 else []
        body = list(first)
        for j in range(4):
            body.append(natural_chord(
                60 + 2 * j,
                articulations=(symbols[(i * 4 + j) % len(symbols)],)))
        bars.append(_Bar("\n".join(body)))
    return source_id, _single_staff(name, bars)


def _ties_source(rng) -> tuple[str, str]:
    """Ties -- chains across barlines and within measures.

    Measure A: two halves, second tied forward across the barline
    (dur=2/4, barLength=4/4 -> fractions = 2/4-4/4 = -2/4, measures=1).
    Measure B: first half receives that tie (prevTotal=4/4, prevDur=2/4
    -> fractions = 4/4-2/4 = +2/4, measures=-1), then two quarters tied
    to each other within the same measure (start: fractions=+1/4 no
    <measures>; stop: fractions=-1/4 no <measures>).

    Ties are not a detector class -- the curve is carried in the label
    file's own `curves` stream -- so this family is sized for structure,
    not for the floor.
    """
    bars = []
    for _ in range(4):
        # A tie chain is one pitch throughout, so the spelling is drawn
        # once and reused rather than going through `natural_chord` per
        # note -- a tie between two different spellings of the same
        # sound is not what this family means to draw.
        p = natural_pitch(int(60 + rng.integers(-4, 5)))
        tpc = tpc_for(p)
        bars.append(_Bar("\n".join(
            ([time_sig(4, 4)] if not bars else [])
            + [chord(p, tpc, duration="half"),
               chord(p, tpc, duration="half", tie="start",
                     tie_fraction="-2/4", tie_measures=1)])))
        bars.append(_Bar("\n".join(
            [chord(p, tpc, duration="half", tie="stop",
                   tie_fraction="2/4", tie_measures=-1),
             chord(p, tpc, duration="quarter", tie="start", tie_fraction="1/4"),
             chord(p, tpc, duration="quarter", tie="stop", tie_fraction="-1/4")])))
    return "cov_ties", _single_staff("Ties", bars)


def coverage_sources(seed: int) -> list[tuple[str, str]]:
    """One source per coverage family. The rng only jitters pitches, so
    class coverage is structural, not sampled."""
    rng = np.random.default_rng(seed)
    sources: list[tuple[str, str]] = []
    sources += _clef_family(rng)
    sources.append(_clef_changes_source(rng))
    sources.append(_accidentals_source())
    sources.append(_dots_source())
    sources.append(_durations_source())
    sources.append(_wholes_source())
    sources.append(_doublewhole_source())
    sources.append(_noteheads_x_source())
    sources.append(_flags_source())
    sources.append(_timesigs_source())
    sources.append(_navigation_source())
    sources.append(_repeats_source())
    sources.append(_grandstaff_source())
    sources.append(_dynamics_source())
    sources.append(_articulation_source("cov_articulations", "Articulations",
                                        _ARTICULATIONS))
    sources.append(_articulation_source("cov_ornaments", "Ornaments",
                                        _ORNAMENTS))
    sources.append(_ties_source(rng))
    return sorted(sources, key=lambda s: s[0])
