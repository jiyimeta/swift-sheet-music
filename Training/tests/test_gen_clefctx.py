import xml.etree.ElementTree as ET
from collections import Counter

from generate import gen_clefctx, validate_mscx


def test_deterministic_and_seed_sensitive():
    a = gen_clefctx.clefctx_sources(seed=7, count=4)
    assert a == gen_clefctx.clefctx_sources(seed=7, count=4)
    assert a != gen_clefctx.clefctx_sources(seed=8, count=4)
    assert [s[0] for s in a] == ["clx_0000", "clx_0001", "clx_0002", "clx_0003"]


def test_zero_count_is_empty():
    assert gen_clefctx.clefctx_sources(seed=7, count=0) == []


def test_sources_are_wellformed_multipart_and_measure_valid():
    for _, text in gen_clefctx.clefctx_sources(seed=7, count=6):
        root = ET.fromstring(text)
        assert root.get("version") == "3.02"
        assert len(root.findall("Score/Part")) >= 2, "one part is not a context"
        staves = root.findall("Score/Staff")
        assert staves and len(staves[0].findall("Measure")) >= 8
        assert list(validate_mscx.measure_problems(text)) == []


def test_every_octave_clef_appears_as_a_system_start_clef():
    """The whole point: each octave variant must occur as a staff's
    `<defaultClef>` (full size, system start), not only as a mid-bar
    change. Over a batch the uniform draw reaches every token."""
    joined = "\n".join(t for _, t in gen_clefctx.clefctx_sources(seed=7, count=40))
    seen = Counter()
    for token in gen_clefctx.CLEF_BASES:
        seen[token] = joined.count(f"<defaultClef>{token}</defaultClef>")
    for token in ("G8va", "G8vb", "G15ma", "G15mb", "F8va", "F8vb", "F15ma", "F15mb", "C3", "F"):
        assert seen[token] > 0, f"{token} never drawn as a default clef: {seen}"
    # `G` is MuseScore's default and is written by omission (see
    # `mscx_builder._part_staff_block`), so it is absent from the count on
    # purpose — every staff without a `<defaultClef>` is a G staff.
    assert "<Clef>" not in joined, "no mid-score changes: context is the variable"


def test_notes_sit_near_their_clef():
    """A staff under `F15mb` must carry low pitches, one under `G15ma`
    high ones — otherwise the clef is decoration and the engraved page
    is a wall of ledger lines the real corpus never shows."""
    for _, text in gen_clefctx.clefctx_sources(seed=11, count=12):
        root = ET.fromstring(text)
        clefs_by_staff: dict[str, str] = {}
        for part in root.findall("Score/Part"):
            for staff in part.findall("Staff"):
                clef = staff.findtext("defaultClef") or "G"
                clefs_by_staff[staff.get("id")] = clef
        for staff in root.findall("Score/Staff"):
            clef = clefs_by_staff[staff.get("id")]
            pitches = [int(p.text) for p in staff.iter("pitch")]
            assert pitches
            base = gen_clefctx.CLEF_BASES[clef]
            mean = sum(pitches) / len(pitches)
            assert abs(mean - base) <= 12, (clef, base, mean)
