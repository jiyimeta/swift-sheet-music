import re
import xml.etree.ElementTree as ET
from pathlib import Path

from generate import gen_coverage


def test_deterministic_byte_identical():
    a = gen_coverage.coverage_sources(seed=42)
    b = gen_coverage.coverage_sources(seed=42)
    assert a == b
    c = gen_coverage.coverage_sources(seed=43)
    assert a != c


def test_every_source_is_wellformed_ms3_xml():
    for source_id, text in gen_coverage.coverage_sources(seed=42):
        root = ET.fromstring(text)
        assert root.tag == "museScore"
        assert root.get("version") == "3.02"
        assert root.find("Score/Division").text == "480"
        assert root.find("Score/Part") is not None
        assert source_id.startswith("cov_")


def test_all_twelve_clefs_are_covered():
    clefs = set()
    for _, text in gen_coverage.coverage_sources(seed=42):
        root = ET.fromstring(text)
        for el in root.findall(".//defaultClef"):
            clefs.add(el.text)
        # A staff with no <defaultClef> is treble (G).
        for staff in root.findall("Score/Part/Staff"):
            if staff.find("defaultClef") is None:
                clefs.add("G")
    assert clefs >= {"G", "G8va", "G8vb", "G15ma", "G15mb",
                     "F", "F8va", "F8vb", "F15ma", "F15mb", "C3", "PERC"}


def test_every_generated_clef_token_is_one_musescore_recognizes():
    """A `<defaultClef>` MuseScore does not recognize is resolved SILENTLY
    to the treble default — no error, no warning, just a G clef where an
    alto clef was asked for. Measured on the first pilot: the family
    emitted a bare `"C"`, every one of its renders came back carrying
    `clefG`, and the `clefC` detector class finished with 0 instances.

    Enumerating the accepted tokens by hand would just re-encode the same
    guess, so read them out of this repo's own reader instead —
    `NotatedClef.init(rawType:)`, whose `default:` branch is exactly the
    silent collapse being guarded against. Same drift-detection shape as
    `test_vocabulary`'s check against `OMRLabelClassNames.swift`.

    The reader is a PROXY for MuseScore, not MuseScore, so a mismatch
    means one of the two is wrong and the pilot's class census says
    which. `KNOWN_READER_GAPS` below records a case where the reader was
    the wrong one: MuseScore does engrave F-clef 15ma / 15mb (the pilot
    counted 32 `clefF15ma` and 32 `clefF15mb` instances, which a silent
    treble fallback could not have produced), but `NotatedClef` has no
    `bass15ma` / `bass15mb` case at all, so a score carrying one reads
    back as treble and every pitch on that staff is wrong. Tracked
    separately; it is an engraving-model gap, not a generator defect.
    """
    KNOWN_READER_GAPS = {"F15ma", "F15mb"}
    repo_root = Path(__file__).resolve().parents[2]
    swift = (repo_root / "Sources" / "SheetMusicCore" / "Score"
             / "NotatedClef.swift").read_text()
    body = swift.split("init(rawType:")[1].split("default:")[0]
    accepted = set(re.findall(r'"([^"]+)"', body))
    # The parse must have found something, or the assertion below is vacuous.
    assert {"G", "F", "C3", "PERC"} <= accepted, sorted(accepted)
    unknown = set(gen_coverage._CLEFS) - accepted - KNOWN_READER_GAPS
    assert not unknown, sorted(unknown)
    # And the recorded gaps must still BE gaps — once the reader learns
    # them, this list has to shrink rather than quietly excuse nothing.
    assert KNOWN_READER_GAPS.isdisjoint(accepted), (
        "NotatedClef now accepts "
        f"{sorted(KNOWN_READER_GAPS & accepted)} — drop it from "
        "KNOWN_READER_GAPS")


def test_ties_are_generated():
    tie_starts = 0
    for _, text in gen_coverage.coverage_sources(seed=42):
        tie_starts += text.count('<Spanner type="Tie">')
    assert tie_starts >= 8  # ties must come from generation (spec §6.1)


def test_rare_duration_and_accidental_coverage():
    joined = "\n".join(t for _, t in gen_coverage.coverage_sources(seed=42))
    assert "<durationType>64th</durationType>" in joined
    assert "<durationType>breve</durationType>" in joined
    # MuseScore writes SMuFL-style subtype names (see the repo's
    # AccidentalType raw values, e.g. "accidentalDoubleSharp").
    assert "<subtype>accidentalDoubleSharp</subtype>" in joined
    assert "<subtype>accidentalDoubleFlat</subtype>" in joined
    assert "<dots>2</dots>" in joined                    # double-dotted
    assert "<Marker>" in joined and "<Jump>" in joined   # segno/coda/D.C./D.S.
    assert "<Fermata>" in joined


def test_common_and_cut_time_symbols_are_covered():
    """MuseScore's TimeSigType ordinal on `<TimeSig><subtype>`: 1 =
    common time "C", 2 = alla breve / cut time "cut-C" (see
    gen_coverage's module docstring for the upstream cross-check).

    Walks `TimeSig` elements rather than grepping for
    `"<subtype>1</subtype>"`: `<subtype>` is a numeric element on Hairpin,
    Jump, Marker and BarLine too, so an unanchored substring check passes
    on a completely unrelated element and would keep passing if the
    common/cut meters were dropped outright (whole-branch review, Minor
    1 -- the same shape `test_cross_barline_ties_carry_measures_and_correct_sign`
    below already uses).
    """
    sources = dict(gen_coverage.coverage_sources(seed=42))
    root = ET.fromstring(sources["cov_timesigs"])
    sigs = root.findall(".//TimeSig")
    assert sigs

    by_subtype = {}
    for sig in sigs:
        subtype = sig.find("subtype")
        # A NORMAL (numeric) time signature omits <subtype> entirely.
        key = None if subtype is None else int(subtype.text)
        by_subtype.setdefault(key, []).append(sig)

    assert set(by_subtype) == {None, 1, 2}
    # Common time is 4/4, cut time is 2/2 -- the glyph must agree with
    # the meter it stands for, or MuseScore draws "C" over 3/4.
    common = by_subtype[1]
    cut = by_subtype[2]
    assert len(common) == gen_coverage.PER_RENDER_TARGET
    assert len(cut) == gen_coverage.PER_RENDER_TARGET
    for sig in common:
        assert (sig.find("sigN").text, sig.find("sigD").text) == ("4", "4")
    for sig in cut:
        assert (sig.find("sigN").text, sig.find("sigD").text) == ("2", "2")
    # `<subtype>` is written BEFORE sigN/sigD, matching MuseScore's own
    # writer (TWrite::write(const TimeSig*, ...)); the reader is
    # order-sensitive, so this is load-bearing, not cosmetic.
    for sig in common + cut:
        assert [child.tag for child in sig][:3] == ["subtype", "sigN", "sigD"]


def test_cross_barline_ties_carry_measures_and_correct_sign():
    """Cross-barline ties must carry <measures> plus a <fractions>
    magnitude signed per MSCXEncoder+Voice+Ties.swift's
    forwardTieLocation/backwardTieLocation — NOT the same-measure shape
    (bare <fractions>, no <measures>). A substring-only check (as in
    test_ties_are_generated) cannot catch a malformed <location> payload;
    this walks the actual Spanner/next|prev/location structure instead.

    Real-fixture cross-check: Tests/SheetMusicTests/Resources/musicxml/
    testUnterminatedTies_ref.mscx:188-198 (start) and :211-221 (stop) show
    MuseScore itself writing <measures>1</measures><fractions>-3/4
    </fractions> for a quarter tied across a 4/4 barline, and
    <measures>-1</measures><fractions>3/4</fractions> on the receiving
    end — <measures> present, and the sign flips between the two sides.
    """
    sources = dict(gen_coverage.coverage_sources(seed=42))
    root = ET.fromstring(sources["cov_ties"])
    starts = root.findall(".//Spanner[@type='Tie']/next/location")
    stops = root.findall(".//Spanner[@type='Tie']/prev/location")

    cross_bar_starts = [loc for loc in starts if loc.find("measures") is not None]
    cross_bar_stops = [loc for loc in stops if loc.find("measures") is not None]
    same_bar_starts = [loc for loc in starts if loc.find("measures") is None]
    same_bar_stops = [loc for loc in stops if loc.find("measures") is None]

    # cov_ties emits exactly one cross-barline tie and one same-measure
    # tie per iteration (4 iterations, see gen_coverage.coverage_sources).
    assert len(cross_bar_starts) == 4
    assert len(cross_bar_stops) == 4
    assert len(same_bar_starts) == 4
    assert len(same_bar_stops) == 4

    for loc in cross_bar_starts:
        assert loc.find("measures").text == "1"
        assert loc.find("fractions").text.startswith("-")

    for loc in cross_bar_stops:
        assert loc.find("measures").text == "-1"
        assert not loc.find("fractions").text.startswith("-")

    for loc in same_bar_starts:
        assert not loc.find("fractions").text.startswith("-")

    for loc in same_bar_stops:
        assert loc.find("fractions").text.startswith("-")


# ---------------------------------------------------------------------------
# Per-class DENSITY.
#
# The first real pilot drew every rare class once or twice per render and
# missed a 1000-instance floor by three orders of magnitude while every
# structural test here stayed green -- because they all asked "is this
# class present?", never "is there enough of it?". These tests ask the
# second question.
#
# They count XML EVIDENCE, not engraved glyphs, so they are a necessary
# condition and not a sufficient one: only a real MuseScore render can
# prove the ink appears (three separate silent-decline bugs -- an invalid
# clef token, a redundant accidental, an unmatched `<musicalSymbolFont>`
# -- all passed XML-level checks). The pilot's class census is the
# sufficient check; this is the one that runs without MuseScore.
# ---------------------------------------------------------------------------


def _roots(seed=42):
    return {sid: ET.fromstring(text)
            for sid, text in gen_coverage.coverage_sources(seed=seed)}


def _chords(roots):
    for root in roots.values():
        yield from root.iter("Chord")


def _rests(roots):
    for root in roots.values():
        yield from root.iter("Rest")


def _duration(element):
    return element.findtext("durationType")


def _count_chords(roots, duration=None, head=None, stem=None):
    n = 0
    for chord in _chords(roots):
        if duration is not None and _duration(chord) != duration:
            continue
        if head is not None and chord.findtext("Note/head") != head:
            continue
        if head is None and chord.findtext("Note/head") is not None:
            continue
        if stem is not None and chord.findtext("StemDirection") != stem:
            continue
        n += 1
    return n


def _count_rests(roots, duration):
    return sum(1 for r in _rests(roots) if _duration(r) == duration)


def _count_accidental(roots, subtype):
    return sum(1 for root in roots.values()
               for acc in root.iter("Accidental")
               if acc.findtext("subtype") == subtype)


def _count_articulation(roots, names):
    return sum(1 for root in roots.values()
               for art in root.iter("Articulation")
               if art.findtext("subtype") in names)


def _count_clef(roots, token):
    """Clefs reaching the page from mid-score `<Clef>` changes. The
    per-clef `<defaultClef>` sources add a few more per render, which
    this deliberately does NOT count -- an unpinned system count is a
    function of the page size the face variant drew, and a floor must
    not depend on that.

    `PERC` is the exception and is counted the other way round, by
    `_count_system_start_clefs`: MuseScore hides a mid-score change to a
    percussion clef on a pitched staff, so the only percussion clefs on
    the page are system starts, and those ARE pinned -- that source
    forces its line breaks."""
    return sum(1 for root in roots.values()
               for clef in root.iter("Clef")
               if clef.findtext("concertClefType") == token)


def _count_system_start_clefs(roots, source_id):
    """Systems in one source, i.e. how many times its `<defaultClef>` is
    engraved. Pinned by the source's own `<LayoutBreak>` elements, one
    system each."""
    staff = roots[source_id].find("Score/Staff")
    return sum(1 for br in staff.iter("LayoutBreak")
               if br.findtext("subtype") == "line")


def _timesig_digits(roots):
    """Digits engraved by numeric time signatures. A `<subtype>` meter
    draws the C / cut-C glyph INSTEAD of digits, so it contributes
    none."""
    counts = {str(d): 0 for d in range(10)}
    for root in roots.values():
        for sig in root.iter("TimeSig"):
            if sig.find("subtype") is not None:
                continue
            for digit in (sig.findtext("sigN") or "") + (sig.findtext("sigD") or ""):
                counts[digit] += 1
    return counts


def _count_timesig_subtype(roots, subtype):
    return sum(1 for root in roots.values() for sig in root.iter("TimeSig")
               if sig.findtext("subtype") == str(subtype))


def _count_marker_sym(roots, sym):
    return sum(1 for root in roots.values() for m in root.iter("Marker")
               if f"<sym>{sym}</sym>" in ET.tostring(m, encoding="unicode"))


def _count_jump_sym(roots, sym):
    return sum(1 for root in roots.values() for j in root.iter("Jump")
               if f"<sym>{sym}</sym>" in ET.tostring(j, encoding="unicode"))


def _count_repeat_barlines(roots):
    return sum(len(root.findall(".//startRepeat")) + len(root.findall(".//endRepeat"))
               for root in roots.values())


def _count_braces(roots):
    """One brace per braced part per SYSTEM. The systems are pinned by
    `<LayoutBreak><subtype>line</subtype>`, which is the whole reason
    this count is knowable without engraving the page."""
    total = 0
    for root in roots.values():
        braced_parts = len(root.findall(".//bracket[@type='1']"))
        if not braced_parts:
            continue
        first_staff = root.find("Score/Staff")
        systems = sum(1 for br in first_staff.iter("LayoutBreak")
                      if br.findtext("subtype") == "line")
        total += braced_parts * systems
    return total


#: class name -> how many instances one render carries, counted from the
#: XML. Only classes the coverage generator is responsible for; see
#: `_TEXTURE_SUPPLIED` and `UNREACHABLE_DETECTOR_CLASSES` for the rest.
_DENSITY = {
    "noteheadWhole": lambda r: _count_chords(r, duration="whole"),
    "noteheadDoubleWhole": lambda r: _count_chords(r, duration="breve"),
    "noteheadXWhole": lambda r: _count_chords(r, duration="whole", head="cross"),
    "noteheadXHalf": lambda r: _count_chords(r, duration="half", head="cross"),
    "flag32ndUp": lambda r: _count_chords(r, duration="32nd", stem="up"),
    "flag32ndDown": lambda r: _count_chords(r, duration="32nd", stem="down"),
    "flag64thUp": lambda r: _count_chords(r, duration="64th", stem="up"),
    "flag64thDown": lambda r: _count_chords(r, duration="64th", stem="down"),
    "augmentationDot": lambda r: sum(int(c.findtext("dots") or 0) for c in _chords(r)),
    "restWhole": lambda r: (_count_rests(r, "whole") + _count_rests(r, "measure")),
    "rest32nd": lambda r: _count_rests(r, "32nd"),
    "rest64th": lambda r: _count_rests(r, "64th"),
    "accidentalSharp": lambda r: _count_accidental(r, "accidentalSharp"),
    "accidentalFlat": lambda r: _count_accidental(r, "accidentalFlat"),
    "accidentalNatural": lambda r: _count_accidental(r, "accidentalNatural"),
    "accidentalDoubleSharp": lambda r: _count_accidental(r, "accidentalDoubleSharp"),
    "accidentalDoubleFlat": lambda r: _count_accidental(r, "accidentalDoubleFlat"),
    "timeSigCommon": lambda r: _count_timesig_subtype(r, 1),
    "timeSigCutTime": lambda r: _count_timesig_subtype(r, 2),
    "repeatBarlineDots": _count_repeat_barlines,
    "brace": _count_braces,
    "segno": lambda r: _count_marker_sym(r, "segno"),
    "coda": lambda r: _count_marker_sym(r, "coda"),
    "dalSegno": lambda r: _count_jump_sym(r, "dalSegno"),
    "daCapo": lambda r: _count_jump_sym(r, "daCapo"),
    "fermata": lambda r: sum(len(root.findall(".//Fermata")) for root in r.values()),
    "dynamic": lambda r: sum(len(root.findall(".//Dynamic")) for root in r.values()),
    "articulation": lambda r: _count_articulation(r, set(gen_coverage._ARTICULATIONS)),
    "ornament": lambda r: _count_articulation(r, set(gen_coverage._ORNAMENTS)),
}
_DENSITY.update({
    f"clef{token.replace('C3', 'C')}":
        (lambda t: (lambda r: _count_clef(r, t)))(token)
    for token in gen_coverage._CLEF_CHANGE_TOKENS
})
_DENSITY["clefPercussion"] = lambda r: _count_system_start_clefs(
    r, gen_coverage._SYSTEM_START_CLEF_SOURCE)
_DENSITY.update({
    f"timeSig{d}": (lambda d: (lambda r: _timesig_digits(r)[d]))(str(d))
    for d in range(10)
})

#: Classes the TEXTURE generator already clears on its own, with the
#: instance count measured on pilot v1 (~/Datasets/sheet-music-omr/v1,
#: 1888 renders, manifest.json -> class_counts). Recorded so the
#: exhaustiveness assertion below cannot be satisfied by forgetting a
#: class: every name here was over the 1000 floor in that run, and the
#: coverage generator's changes do not touch the texture generator.
_TEXTURE_SUPPLIED = {
    "noteheadBlack": 220432, "noteheadXBlack": 29440, "noteheadHalf": 27712,
    "flag16thUp": 23200, "flag8thDown": 8704, "flag16thDown": 8384,
    "flag8thUp": 6848, "clefG": 6700, "timeSig4": 6359, "rest16th": 5136,
    "rest8th": 4928, "restQuarter": 3840, "clefF": 2858, "restHalf": 2480,
    "clefG8vb": 1545, "clefPercussion": 1136,
}


def test_renders_per_source_matches_the_face_matrix():
    """`PER_RENDER_TARGET` is only meaningful against the number of
    renders one source receives. Read that out of the face matrix rather
    than restating it, so adding or dropping a face fails here instead of
    silently halving every class count in the next pilot."""
    from generate import style_matrix
    per_face = 2  # the runbook's standard invocation
    assert gen_coverage.RENDERS_PER_SOURCE == len(style_matrix.FACES["ms4"]) * per_face
    assert (gen_coverage.PER_RENDER_TARGET * gen_coverage.RENDERS_PER_SOURCE
            >= gen_coverage.CLASS_FLOOR)


def test_density_table_is_exhaustive_over_the_frozen_vocabulary():
    """Every detector class must be accounted for exactly once: drawn by
    the coverage generator, supplied by the textures, or recorded as
    unreachable. A class that is in none of the three is one nobody is
    generating -- which is precisely how 17 classes reached the first
    pilot at zero."""
    from generate import vocabulary
    accounted = (set(_DENSITY) | set(_TEXTURE_SUPPLIED)
                 | set(gen_coverage.UNREACHABLE_DETECTOR_CLASSES))
    assert accounted == set(vocabulary.CLASS_NAMES), {
        "unaccounted": sorted(set(vocabulary.CLASS_NAMES) - accounted),
        "not-a-class": sorted(accounted - set(vocabulary.CLASS_NAMES)),
    }
    # The texture counts are evidence, not aspiration: each was measured
    # above the floor on pilot v1.
    for name, measured in _TEXTURE_SUPPLIED.items():
        assert measured >= gen_coverage.CLASS_FLOOR, name


def test_every_coverage_class_clears_the_per_render_target():
    roots = _roots()
    short = {name: counter(roots) for name, counter in _DENSITY.items()
             if counter(roots) < gen_coverage.PER_RENDER_TARGET}
    assert not short, short


def test_unreachable_classes_are_real_classes_and_are_not_generated():
    """`fine` / `toCoda` have no SMuFL glyph, so nothing can draw them.
    Guard both directions: they must still BE classes (the vocabulary is
    frozen, so they cannot be deleted), and they must not appear in the
    density table pretending to be covered."""
    from generate import vocabulary
    unreachable = set(gen_coverage.UNREACHABLE_DETECTOR_CLASSES)
    assert unreachable <= set(vocabulary.CLASS_NAMES)
    assert unreachable.isdisjoint(_DENSITY)
    for reason in gen_coverage.UNREACHABLE_DETECTOR_CLASSES.values():
        assert reason.strip()


def test_meter_rotation_never_repeats_a_meter_back_to_back():
    """MuseScore engraves a time signature only when it CHANGES, so two
    equal neighbours draw one signature and the density arithmetic is
    silently halved. The wrap-around pair counts: the rotation repeats,
    so its last entry neighbours its own first."""
    rotation = gen_coverage._METER_ROTATION
    for i, entry in enumerate(rotation):
        assert entry != rotation[(i + 1) % len(rotation)], i


def test_short_notes_are_kept_off_beams_two_independent_ways():
    """A beamed 32nd draws no flag, which is why `flag32ndUp` and its
    three siblings finished the first pilot at zero. Both guards must be
    present on every short chord: `<BeamMode>no</BeamMode>`, and a rest
    of the same length between consecutive notes."""
    root = _roots()["cov_flags"]
    for measure in root.iter("Measure"):
        elements = [el for el in measure.find("voice")
                    if el.tag in ("Chord", "Rest")]
        assert elements
        for el in elements:
            if el.tag != "Chord":
                continue
            assert el.findtext("BeamMode") == "no"
            assert el.findtext("StemDirection") in ("up", "down")
        # Chords and rests strictly alternate, same duration throughout.
        tags = [el.tag for el in elements]
        assert tags == ["Chord", "Rest"] * (len(tags) // 2)
        durations = {el.findtext("durationType") for el in elements}
        assert len(durations) == 1


def test_every_clef_change_writes_both_clef_types():
    """Writing only `<concertClefType>` engraves a TREBLE CLEF for every
    token, silently. `Clef::clefType()` returns the concert clef only in
    concert-pitch mode and the transposing clef otherwise (upstream
    `dom/clef.cpp:209-216`), a score is not in concert pitch by default,
    and the transposing clef defaults to `ClefType::G` when the element
    is absent (`rw/read400/tread.cpp:2568-2571`).

    Measured, not reasoned: a probe run of `cov_clef_changes` with the
    concert element alone came back carrying 840 extra `clefG` and two
    each of the other eleven clef classes.

    The two tokens must also AGREE — these are non-transposing parts, so
    a mismatch would engrave one clef and mean another.
    """
    roots = _roots()
    seen = set()
    for root in roots.values():
        for clef in root.iter("Clef"):
            concert = clef.findtext("concertClefType")
            transposing = clef.findtext("transposingClefType")
            assert concert is not None
            assert transposing == concert, (concert, transposing)
            seen.add(concert)
    assert seen == set(gen_coverage._CLEF_CHANGE_TOKENS), sorted(seen)


def test_no_mid_score_change_asks_for_a_clef_musescore_will_hide():
    """A clef change whose `ClefInfo::staffGroup` disagrees with the
    staff's is hidden outright past tick 0 — `show = false`,
    `symId = noSym`, and a debug log no headless export prints
    (upstream `rendering/score/tlayout.cpp:1657-1674`). On a pitched
    staff that is exactly the percussion clef, which is why it is out of
    the rotation and drawn from system starts instead.

    Both directions, so the exclusion cannot rot: `PERC` must stay out of
    the change tokens, and must stay in `_CLEFS` — the `<defaultClef>`
    path does engrave it, and dropping it there would lose the class.
    """
    assert "PERC" in gen_coverage._CLEFS
    assert "PERC" not in gen_coverage._CLEF_CHANGE_TOKENS
    assert set(gen_coverage._CLEF_CHANGE_TOKENS) == set(gen_coverage._CLEFS) - {"PERC"}
    sources = dict(gen_coverage.coverage_sources(seed=42))
    assert gen_coverage._SYSTEM_START_CLEF_SOURCE in sources
    assert _count_system_start_clefs(
        _roots(), gen_coverage._SYSTEM_START_CLEF_SOURCE
    ) >= gen_coverage.PER_RENDER_TARGET


def test_no_bar_is_left_to_be_filled_with_a_double_whole_rest():
    """A full-measure rest in a bar LONGER than a whole note comes back
    as `restDoubleWhole` (U+E4E2) — a glyph with no detector class, and a
    duration this package's `NoteDuration` cannot decode. Measured: every
    10/4 bar of an earlier probe produced `unknownE4E2`, 70 in one
    render.

    So a long bar is filled with explicit rests instead, and the fill has
    to close exactly — `validate_mscx` would catch an underfull bar, but
    only after the generator had already been trusted.
    """
    from fractions import Fraction

    from generate import mscx_builder
    for n, d in [(2, 4), (4, 4), (2, 2), (5, 4), (9, 8), (10, 4), (12, 8)]:
        body = mscx_builder.bar_of_rests(n, d)
        bar = ET.fromstring(f"<voice>{body}</voice>")
        if Fraction(n, d) <= 1:
            assert [el.findtext("durationType") for el in bar] == ["measure"]
            continue
        total = sum((dict(mscx_builder._REST_DENOMINATIONS)[el.findtext("durationType")]
                     for el in bar), Fraction(0))
        assert total == Fraction(n, d), (n, d, total)
        assert "measure" not in [el.findtext("durationType") for el in bar]

    # And the family that needs it actually uses it.
    root = _roots()["cov_timesigs"]
    for measure in root.iter("Measure"):
        sig = measure.find("voice/TimeSig")
        n, d = int(sig.findtext("sigN")), int(sig.findtext("sigD"))
        durations = [el.findtext("durationType")
                     for el in measure.find("voice") if el.tag == "Rest"]
        assert ("measure" in durations) == (Fraction(n, d) <= 1), (n, d, durations)


def test_grand_staff_part_carries_a_brace_and_a_spanning_barline():
    """The brace is a `<Part>`-level `<bracket type="1">` on the FIRST
    staff of a multi-staff part, paired with `<barLineSpan>` on every
    staff but the last -- the shape MuseScore itself writes in
    testMeasureRepeats.mscx:26-38. A brace declared on the wrong staff,
    or a `span` that does not match the staff count, is dropped
    silently."""
    root = _roots()["cov_grandstaff"]
    parts = root.findall("Score/Part")
    assert parts
    score_staves = root.findall("Score/Staff")
    assert len(score_staves) == sum(len(p.findall("Staff")) for p in parts)
    # Score-level staff ids are unique and continue across parts.
    ids = [s.get("id") for s in score_staves]
    assert ids == [str(i) for i in range(1, len(ids) + 1)]
    for part in parts:
        part_staves = part.findall("Staff")
        assert len(part_staves) == 2
        brackets = part_staves[0].findall("bracket")
        assert len(brackets) == 1
        assert brackets[0].get("type") == "1"          # BracketType.brace
        assert brackets[0].get("span") == str(len(part_staves))
        assert part_staves[0].findtext("barLineSpan") == "1"
        assert part_staves[-1].find("bracket") is None
        assert part_staves[-1].findtext("barLineSpan") is None
