from fractions import Fraction

import pytest

from generate import gen_coverage, gen_texture, validate_mscx


def document(measures: list[str], staff_attrs: str = "") -> str:
    """Minimal one-staff document around already-rendered measure bodies.

    Deliberately hand-built rather than routed through
    `gen_coverage.mscx_document`, so a generator regression cannot make
    these unit cases pass by changing what they are testing.
    """
    bars = "\n".join(
        f"      <Measure{attrs}>\n        <voice>\n{body}\n"
        "        </voice>\n      </Measure>"
        for body, attrs in measures
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<museScore version="3.02">\n  <Score>\n'
        "    <Division>480</Division>\n"
        f'    <Staff id="1"{staff_attrs}>\n{bars}\n    </Staff>\n'
        "  </Score>\n</museScore>\n"
    )


def bar(body: str, attrs: str = "") -> tuple[str, str]:
    return (body, attrs)


TIME_SIG_44 = (
    "          <TimeSig>\n            <sigN>4</sigN>\n"
    "            <sigD>4</sigD>\n          </TimeSig>"
)


def rest(duration: str) -> str:
    return f"          <Rest>\n            <durationType>{duration}</durationType>\n          </Rest>"


def note(duration: str = "quarter", dots: int = 0, extra: str = "") -> str:
    dots_el = f"            <dots>{dots}</dots>\n" if dots else ""
    return (
        "          <Chord>\n"
        f"{dots_el}"
        f"            <durationType>{duration}</durationType>\n"
        f"{extra}"
        "            <Note>\n              <pitch>60</pitch>\n"
        "              <tpc>14</tpc>\n            </Note>\n"
        "          </Chord>"
    )


def test_exact_bar_has_no_problems():
    text = document([bar("\n".join([TIME_SIG_44] + [note()] * 4))])
    assert validate_mscx.measure_problems(text) == []


def test_overfull_bar_is_reported_with_both_sums():
    text = document([bar("\n".join([TIME_SIG_44] + [note()] * 6))])
    (problem,) = validate_mscx.measure_problems(text)
    assert problem.kind == "over"
    assert problem.actual == Fraction(6, 4)
    assert problem.expected == Fraction(1)
    assert problem.measure == 1 and problem.voice == 1
    assert "OVER" in str(problem)


def test_underfull_bar_is_reported():
    text = document([bar("\n".join([TIME_SIG_44] + [note()] * 3))])
    (problem,) = validate_mscx.measure_problems(text)
    assert problem.kind == "under"
    assert problem.actual == Fraction(3, 4)


def test_dots_extend_the_written_duration():
    """A dotted half plus a quarter is exactly 4/4 -- if dots were
    ignored the bar would read 3/4 and report UNDER."""
    text = document([bar("\n".join([TIME_SIG_44, note("half", dots=1), note()]))])
    assert validate_mscx.measure_problems(text) == []


def test_double_dots_extend_by_seven_quarters_of_the_base():
    body = "\n".join([TIME_SIG_44, note("quarter", dots=2), note("16th"),
                      rest("quarter"), rest("quarter")])
    assert validate_mscx.measure_problems(document([bar(body)])) == []


def test_meter_carries_into_later_bars_of_the_same_staff():
    """The second bar declares no `<TimeSig>`; judging it against a
    default 4/4 instead of the inherited 3/4 would miss the shortfall."""
    three_four = TIME_SIG_44.replace("<sigN>4</sigN>", "<sigN>3</sigN>")
    text = document([
        bar("\n".join([three_four] + [note()] * 3)),
        bar("\n".join([note()] * 4)),
    ])
    (problem,) = validate_mscx.measure_problems(text)
    assert problem.measure == 2
    assert (problem.kind, problem.actual, problem.expected) == (
        "over", Fraction(1), Fraction(3, 4))


def test_grace_chords_are_not_charged_to_the_bar():
    """Plan bug #3: a grace note carries a written durationType but
    MuseScore re-derives bar length without it, so counting it would
    report every graced bar as OVER."""
    graced = note("eighth", extra="            <acciaccatura/>\n")
    text = document([bar("\n".join([TIME_SIG_44, graced] + [note()] * 4))])
    assert validate_mscx.measure_problems(text) == []


def test_every_grace_tag_is_recognized():
    for tag in validate_mscx.GRACE_TAGS:
        graced = note("eighth", extra=f"            <{tag}/>\n")
        text = document([bar("\n".join([TIME_SIG_44, graced] + [note()] * 4))])
        assert validate_mscx.measure_problems(text) == [], tag


def test_tuplet_members_are_scaled_by_the_ratio():
    """Three eighths under a 3:2 tuplet occupy one quarter, not three.
    Unscaled they would read 3/8 and the bar would report OVER."""
    tuplet = (
        "          <Tuplet>\n            <normalNotes>2</normalNotes>\n"
        "            <actualNotes>3</actualNotes>\n"
        "            <baseNote>eighth</baseNote>\n          </Tuplet>"
    )
    body = "\n".join(
        [TIME_SIG_44, tuplet] + [note("eighth")] * 3
        + ["          <endTuplet/>"] + [note()] * 3)
    assert validate_mscx.measure_problems(document([bar(body)])) == []


def test_tuplet_scaling_stops_at_endTuplet():
    """The ratio must not leak past `<endTuplet/>`: if it did, the three
    trailing quarters would each be counted as 1/6 and the bar would
    read short instead of exact."""
    tuplet = (
        "          <Tuplet>\n            <normalNotes>2</normalNotes>\n"
        "            <actualNotes>3</actualNotes>\n          </Tuplet>"
    )
    leaked = "\n".join(
        [TIME_SIG_44, tuplet] + [note("eighth")] * 3
        + [note()] * 3)  # no endTuplet -- the trailing quarters get scaled
    (problem,) = validate_mscx.measure_problems(document([bar(leaked)]))
    assert problem.kind == "under"
    assert problem.actual == Fraction(1, 4) + Fraction(3, 4) * Fraction(2, 3)


def test_measure_len_attribute_overrides_the_meter():
    """A pickup bar written `len="1/4"` holds one quarter and is
    correct; judged against 4/4 it would report UNDER."""
    text = document([bar("\n".join([TIME_SIG_44, note()]), attrs=' len="1/4"')])
    assert validate_mscx.measure_problems(text) == []


def test_full_measure_rest_fills_whatever_the_bar_is():
    three_four = TIME_SIG_44.replace("<sigN>4</sigN>", "<sigN>3</sigN>")
    text = document([bar("\n".join([three_four, rest("measure")]))])
    assert validate_mscx.measure_problems(text) == []


def test_undecodable_duration_token_is_reported_not_silently_skipped():
    """`breve` is absent from this package's `NoteDuration(mscxName:)`,
    so a source using it cannot be parsed by the back-end at all. It
    must surface, not vanish into a sum."""
    text = document([bar("\n".join([TIME_SIG_44, note("breve")]))])
    (problem,) = validate_mscx.measure_problems(text)
    assert problem.kind == "unknown-duration"
    assert problem.detail == "breve"
    assert "breve" in str(problem)


def test_second_voice_is_judged_against_the_meter_declared_in_voice_one():
    """A meter change is written into voice 1 only but governs the whole
    bar. Reading `<TimeSig>` per voice would judge voice 2 against 4/4
    and report a correct 3/4 voice as UNDER."""
    three_four = TIME_SIG_44.replace("<sigN>4</sigN>", "<sigN>3</sigN>")
    body_one = "\n".join([three_four] + [note()] * 3)
    body_two = "\n".join([note()] * 3)
    text = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<museScore version="3.02">\n  <Score>\n    <Staff id="1">\n'
        f"      <Measure>\n        <voice>\n{body_one}\n        </voice>\n"
        f"        <voice>\n{body_two}\n        </voice>\n      </Measure>\n"
        "    </Staff>\n  </Score>\n</museScore>\n"
    )
    assert validate_mscx.measure_problems(text) == []


def test_each_staff_starts_from_its_own_default_meter():
    """Staff 2 must not inherit staff 1's trailing meter."""
    three_four = TIME_SIG_44.replace("<sigN>4</sigN>", "<sigN>3</sigN>")
    body_one = "\n".join([three_four] + [note()] * 3)
    body_two = "\n".join([note()] * 4)
    text = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<museScore version="3.02">\n  <Score>\n'
        f'    <Staff id="1">\n      <Measure>\n        <voice>\n{body_one}\n'
        "        </voice>\n      </Measure>\n    </Staff>\n"
        f'    <Staff id="2">\n      <Measure>\n        <voice>\n{body_two}\n'
        "        </voice>\n      </Measure>\n    </Staff>\n"
        "  </Score>\n</museScore>\n"
    )
    assert validate_mscx.measure_problems(text) == []


# --- Regression guard over the real generators -------------------------
# These are the tests that would have caught the two measured pilot
# failures (cov_durations overfull -> MuseScore abort; cov_timesigs
# underfull -> silent pad). They run the shipping generators, not a
# fixture, so a future edit to either one cannot reintroduce the class.

@pytest.mark.parametrize("seed", [42, 20260806, 20260807])
def test_every_coverage_source_is_measure_exact(seed):
    for source_id, text in gen_coverage.coverage_sources(seed=seed):
        problems = validate_mscx.measure_problems(text)
        if source_id in gen_coverage.UNDECODABLE_DURATION_SOURCES:
            # Documented, isolated exception -- see that constant.
            assert all(p.kind == "unknown-duration" for p in problems), (
                source_id, [str(p) for p in problems])
            continue
        assert problems == [], (source_id, [str(p) for p in problems])


@pytest.mark.parametrize("seed", [42, 20260807])
def test_every_texture_source_is_measure_exact(seed):
    for source_id, text in gen_texture.texture_sources(seed=seed, count=40):
        problems = validate_mscx.measure_problems(text)
        assert problems == [], (source_id, [str(p) for p in problems])
