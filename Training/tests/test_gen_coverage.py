import xml.etree.ElementTree as ET

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
                     "F", "F8va", "F8vb", "F15ma", "F15mb", "C", "PERC"}


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
    # MuseScore's TimeSigType ordinal on <TimeSig><subtype>: 1 = common
    # time "C", 2 = alla breve/cut time "cut-C" (see gen_coverage's
    # module docstring for the upstream cross-check).
    joined = "\n".join(t for _, t in gen_coverage.coverage_sources(seed=42))
    assert "<subtype>1</subtype>" in joined
    assert "<subtype>2</subtype>" in joined


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
