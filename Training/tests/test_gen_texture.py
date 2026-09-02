import xml.etree.ElementTree as ET

from generate import gen_texture


def test_deterministic_and_seed_sensitive():
    a = gen_texture.texture_sources(seed=7, count=4)
    assert a == gen_texture.texture_sources(seed=7, count=4)
    assert a != gen_texture.texture_sources(seed=8, count=4)
    assert [s[0] for s in a] == ["tex_0000", "tex_0001", "tex_0002", "tex_0003"]


def test_sources_are_wellformed_and_multibar():
    for _, text in gen_texture.texture_sources(seed=7, count=4):
        root = ET.fromstring(text)
        assert root.get("version") == "3.02"
        staves = root.findall("Score/Staff")
        assert staves, "no content staff"
        assert len(staves[0].findall("Measure")) >= 8


def test_feature_mix_appears_across_a_batch():
    joined = "\n".join(t for _, t in gen_texture.texture_sources(seed=7, count=12))
    assert "<Tuplet>" in joined                       # tuplets
    assert "<acciaccatura/>" in joined                # grace notes
    assert "<Lyrics>" in joined                       # lyric syllables
    assert 'group="percussion"' in joined             # drum staff
    assert joined.count("<Part>") > 12                # some multi-part scores
    assert "eighth" in joined and "16th" in joined    # beamable runs


def test_multivoice_measures_exist():
    joined = "\n".join(t for _, t in gen_texture.texture_sources(seed=7, count=12))
    # A measure with two <voice> blocks serializes as two voice elements.
    assert joined.count("<voice>") > joined.count("<Measure>")


def test_tuplet_structure_matches_actual_notes_count():
    """A <Tuplet> marker's actualNotes must equal the number of member
    <Chord> elements before the matching <endTuplet/> — a substring
    count of "<Tuplet>" occurrences (as in the feature-mix test above)
    would not catch a mismatched member count or a missing close."""
    sources = gen_texture.texture_sources(seed=7, count=12)
    checked = 0
    for _, text in sources:
        root = ET.fromstring(text)
        for voice in root.iter("voice"):
            children = list(voice)
            i = 0
            while i < len(children):
                el = children[i]
                if el.tag == "Tuplet":
                    normal = int(el.findtext("normalNotes"))
                    actual = int(el.findtext("actualNotes"))
                    base = el.findtext("baseNote")
                    # normalNotes is "in the time of N normal notes";
                    # actualNotes is the number of notes played. Most
                    # tuplets in this generator are actual > normal
                    # (triplet 3:2, quintuplet 5:4) but the 7:8 septuplet
                    # is the reverse (7 actual notes in the time of 8),
                    # so only positivity is asserted here, not ordering.
                    assert normal > 0 and actual > 0
                    assert base in {"eighth", "16th", "32nd"}
                    j = i + 1
                    member_count = 0
                    while j < len(children) and children[j].tag != "endTuplet":
                        assert children[j].tag == "Chord", (
                            f"tuplet member must be a Chord, got {children[j].tag}"
                        )
                        member_count += 1
                        j += 1
                    assert j < len(children), "Tuplet has no matching <endTuplet/>"
                    assert member_count == actual, (
                        f"Tuplet declares actualNotes={actual} but has "
                        f"{member_count} member chords before <endTuplet/>"
                    )
                    checked += 1
                i += 1
    assert checked > 0, "no <Tuplet> exercised the structural check"


def test_grace_chord_attaches_before_an_ordinary_chord():
    """A grace <Chord> (<acciaccatura/>) must sit immediately before an
    ordinary chord/rest in voice order and carry exactly one note — it
    must not itself be counted as consuming the bar (see gen_texture's
    module docstring on why a grace note must never be the bar-filling
    note it precedes)."""
    sources = gen_texture.texture_sources(seed=7, count=12)
    checked = 0
    for _, text in sources:
        root = ET.fromstring(text)
        for voice in root.iter("voice"):
            children = list(voice)
            for i, el in enumerate(children):
                if el.tag == "Chord" and el.find("acciaccatura") is not None:
                    assert len(el.findall("Note")) == 1
                    assert i + 1 < len(children), "grace chord has no following element"
                    nxt = children[i + 1]
                    assert nxt.tag in ("Chord", "Rest")
                    if nxt.tag == "Chord":
                        assert nxt.find("acciaccatura") is None, (
                            "grace chord must not be followed by another grace chord"
                        )
                    checked += 1
    assert checked > 0, "no grace chord exercised the structural check"


def test_second_voice_is_a_full_bar_measure_sibling():
    """The injected second <voice> is a sibling of the first inside the
    same <Measure> (per MSCXDecoder+Measure.swift's `node.all("voice")`)
    and its two half notes exactly fill a 4/4 bar."""
    sources = gen_texture.texture_sources(seed=7, count=12)
    checked = 0
    for _, text in sources:
        root = ET.fromstring(text)
        for measure in root.iter("Measure"):
            voices = measure.findall("voice")
            if len(voices) < 2:
                continue
            second_voice_chords = voices[1].findall("Chord")
            assert len(second_voice_chords) == 2
            for c in second_voice_chords:
                assert c.findtext("durationType") == "half"
                assert len(c.findall("Note")) == 1
            checked += 1
    assert checked > 0, "no two-voice measure exercised the structural check"


def test_drum_notes_carry_cross_notehead_override():
    """Every note in a percussion-group score carries the <head>cross
    </head> override that produces X-noteheads — the substring check
    'group="percussion"' in joined (feature-mix test above) only proves
    the staff type, not that any note actually renders with an X-head."""
    sources = gen_texture.texture_sources(seed=7, count=12)
    checked = 0
    for _, text in sources:
        root = ET.fromstring(text)
        if not root.findall(".//StaffType[@group='percussion']"):
            continue
        for staff in root.findall("Score/Staff"):
            for note in staff.iter("Note"):
                assert note.findtext("head") == "cross"
                checked += 1
    assert checked > 0, "no drum note exercised the structural check"
