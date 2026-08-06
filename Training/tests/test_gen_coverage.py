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
