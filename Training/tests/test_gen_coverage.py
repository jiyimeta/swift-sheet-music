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
    assert len(common) == 1
    assert len(cut) == 1
    assert (common[0].find("sigN").text, common[0].find("sigD").text) == ("4", "4")
    assert (cut[0].find("sigN").text, cut[0].find("sigD").text) == ("2", "2")
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
