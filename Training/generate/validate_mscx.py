"""Measure-length validator for generated `.mscx` sources.

WHY THIS EXISTS. A generated measure whose voice does not sum to the
prevailing time signature fails in two different ways, and only one of
them is loud:

- **Overfull** — MuseScore 4 aborts during layout
  (`libc++abi: … mutex lock failed: Invalid argument`) and writes no
  PDF at all, so every render of that source is quarantined. Measured:
  `cov_durations` shipped a 4/4 bar holding 6 quarters, which cost all
  8 of its faces on the first real pilot run.
- **Underfull** — MuseScore accepts it silently and pads the bar. The
  render looks plausible, the labels describe what was drawn, and the
  score-level ground truth parsed back out of `source.mscx` describes
  something shorter. Nothing anywhere reports it. Measured:
  `cov_timesigs` filled its 7/8 and 9/8 bars with quarter notes.

Counting elements or grepping for a duration token cannot catch either
(the same lesson the Task 11 tie bug taught: a test that counts
`<Spanner type="Tie">` passes on structurally broken output). So this
validator sums the actual voice content and compares it against the
meter, which is the structure the bug lives in.

WHAT IT MIRRORS. Durations, dots and tuplet scaling follow this repo's
own decoder rather than a reading of the MuseScore schema:

- duration tokens and the dot factor: `NoteDuration(mscxName:)` and
  `NoteDuration.dotted(_:)` (`Sources/SheetMusicCore/Score/NoteDuration.swift`).
  `breve` / `long` are deliberately ABSENT there, so they are absent
  here too and report as `unknown-duration` — a source using one cannot
  be parsed by this package's back-end at all
  (`MSCXDecoder+Chord.swift` throws `malformedScore`), which is worth a
  loud line rather than a silent pass.
- tuplets scale by `normalNotes / actualNotes` from the flat
  `<Tuplet> … <endTuplet/>` sibling markers, stack-based for nesting,
  matching `MSCXDecoder+Voice.swift`'s `tupletStack` / `tupletFractions()`.
  The written `<duration>` element is ignored for the same reason the
  decoder ignores it: it reads durationType and scales it itself.
- grace chords are NOT charged to the bar. A grace `<Chord>` is a
  sibling carrying one of `GraceType.mscxTag`'s eight tags
  (`Sources/SheetMusicCore/Score/GraceType.swift`), and
  `MSCXDecoder+Voice.swift` `continue`s before advancing its cursor for
  one. Charging them was plan bug #3.

Durations are carried as `Fraction` in WHOLE-NOTE units, so a time
signature `n/d` is `Fraction(n, d)` with no conversion, and every
comparison is exact — no float tolerance anywhere.

NOT MODELLED (none of the generators emit these; each would need its
own evidence before being added): a `<TimeSig>` appearing part-way
through a bar (the meter is taken from whichever `<TimeSig>` the
measure carries, wherever it sits), and `<measureRepeat>`.
"""

import xml.etree.ElementTree as ET
from dataclasses import dataclass
from fractions import Fraction

#: `<durationType>` token → length in whole notes. Mirrors
#: `NoteDuration(mscxName:)`; `breve`/`long` are absent there and here.
DURATION_TOKENS = {
    "whole": Fraction(1),
    "half": Fraction(1, 2),
    "quarter": Fraction(1, 4),
    "eighth": Fraction(1, 8),
    "16th": Fraction(1, 16),
    "32nd": Fraction(1, 32),
    "64th": Fraction(1, 64),
    "128th": Fraction(1, 128),
    "256th": Fraction(1, 256),
}

#: A `<Chord>` carrying any of these child tags is a grace note and is
#: not charged to the bar. Mirrors `GraceType.mscxTag` exactly.
GRACE_TAGS = frozenset({
    "acciaccatura", "appoggiatura", "grace4", "grace16", "grace32",
    "grace8after", "grace16after", "grace32after",
})

#: `<durationType>measure</durationType>` — a rest that fills whatever
#: the bar is, by definition. `NoteDuration.measure`.
MEASURE_REST = "measure"


@dataclass(frozen=True)
class MeasureProblem:
    """One voice of one measure that does not sum to its meter.

    `kind` is `over` / `under` / `unknown-duration`. `actual` and
    `expected` are whole-note `Fraction`s and are `None` for
    `unknown-duration`, where no sum could be formed.
    """
    staff: str
    measure: int
    voice: int
    kind: str
    actual: Fraction | None = None
    expected: Fraction | None = None
    detail: str = ""

    def __str__(self) -> str:
        where = f"staff{self.staff} m{self.measure} v{self.voice}"
        if self.kind == "unknown-duration":
            return f"{where}: unknown durationType {self.detail!r}"
        return (f"{where}: {self.kind.upper()} "
                f"sum={self.actual} expected={self.expected}")


def _element_duration(element) -> Fraction | None:
    """Written duration of one `<Chord>`/`<Rest>` in whole notes, before
    tuplet scaling. `None` when the token is one this package cannot
    decode (`breve`, `long`, a typo)."""
    token = element.findtext("durationType")
    base = DURATION_TOKENS.get(token)
    if base is None:
        return None
    dots = int(element.findtext("dots") or 0)
    # Each dot adds half of the running length: 1 dot = 3/2, 2 = 7/4.
    # Mirrors NoteDuration.dotted(_:) -- ((1 << (dots+1)) - 1) / (1 << dots).
    return base * Fraction((1 << (dots + 1)) - 1, 1 << dots)


def _measure_meter(measure, inherited: Fraction) -> Fraction:
    """The meter in force for `measure`: its own `<TimeSig>` if it
    carries one in ANY voice, else the one inherited from the previous
    measure of this staff.

    Read across all voices on purpose. A meter change is written into
    voice 1 only, but it governs every voice in the bar, so a per-voice
    scan would judge voice 2 against the previous meter.
    """
    for voice in measure.findall("voice"):
        sig = voice.find("TimeSig")
        if sig is not None:
            n = int(sig.findtext("sigN") or 4)
            d = int(sig.findtext("sigD") or 4)
            return Fraction(n, d)
    return inherited


def _voice_problems(voice, expected: Fraction, staff_id: str,
                    measure_index: int, voice_index: int) -> list[MeasureProblem]:
    problems: list[MeasureProblem] = []
    total = Fraction(0)
    tuplet_stack: list[Fraction] = []
    for element in voice:
        if element.tag == "Tuplet":
            normal = int(element.findtext("normalNotes") or 1)
            actual = int(element.findtext("actualNotes") or 1)
            tuplet_stack.append(Fraction(normal, actual))
            continue
        if element.tag == "endTuplet":
            if tuplet_stack:
                tuplet_stack.pop()
            continue
        if element.tag not in ("Chord", "Rest"):
            continue
        if element.tag == "Chord" and any(c.tag in GRACE_TAGS for c in element):
            continue  # grace notes are not charged to the bar
        if element.findtext("durationType") == MEASURE_REST:
            total += expected
            continue
        written = _element_duration(element)
        if written is None:
            problems.append(MeasureProblem(
                staff=staff_id, measure=measure_index, voice=voice_index,
                kind="unknown-duration",
                detail=element.findtext("durationType") or "",
            ))
            continue
        scale = Fraction(1)
        for ratio in tuplet_stack:
            scale *= ratio
        total += written * scale
    # An undecodable token means part of the bar has no length, so the
    # sum below is not a fact about the music -- reporting OVER/UNDER on
    # top of it would be inventing a second finding from the first one.
    # The bar's *other* voices, and every other bar, are still checked.
    if not problems and total != expected:
        problems.append(MeasureProblem(
            staff=staff_id, measure=measure_index, voice=voice_index,
            kind="over" if total > expected else "under",
            actual=total, expected=expected,
        ))
    return problems


def measure_problems(mscx_text: str) -> list[MeasureProblem]:
    """Every voice of every measure whose content does not sum to the
    bar it sits in. An empty list means the document is measure-exact.

    A `<Measure len="a/b">` attribute overrides the meter for that bar
    (that is what it is for -- pickup and irregular bars), so such a bar
    is checked against `len`, not against the time signature.
    """
    problems: list[MeasureProblem] = []
    root = ET.fromstring(mscx_text)
    for staff in root.findall("./Score/Staff"):
        staff_id = staff.get("id") or "?"
        meter = Fraction(4, 4)
        for measure_index, measure in enumerate(staff.findall("Measure"), start=1):
            meter = _measure_meter(measure, meter)
            declared = measure.get("len")
            expected = Fraction(declared) if declared else meter
            for voice_index, voice in enumerate(measure.findall("voice"), start=1):
                problems.extend(_voice_problems(
                    voice, expected, staff_id, measure_index, voice_index))
    return problems
