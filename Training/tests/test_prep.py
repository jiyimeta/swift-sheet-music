import json
from pathlib import Path

from model import prep


def _write_page(root: Path, render_id: str, source_id: str, page_index: int,
                 face: str = "ms4/Bravura"):
    d = root / render_id
    d.mkdir(parents=True, exist_ok=True)
    (d / f"page_{page_index}.prep.json").write_text(json.dumps({
        "schema": 1, "render_id": render_id, "source_id": source_id,
        "face": face, "page_index": page_index,
        "image": {"file": f"page_{page_index}.prep.png", "width_px": 100,
                  "height_px": 80, "staff_space_px": 12.0, "scale": 0.5,
                  "source_width_px": 200, "source_height_px": 160,
                  "source_dpi": 300.0, "deskew_degrees": 0.0},
        "glyphs": [{"class": "noteheadBlack", "center_px": [10.0, 20.0],
                    "origin_px": [4.0, 20.0], "advance_px": 12.0,
                    "rendered_size_px": 9.0}],
    }))


def test_index_finds_every_page(tmp_path):
    _write_page(tmp_path, "r_a_v0", "src_a", 0)
    _write_page(tmp_path, "r_a_v0", "src_a", 1)
    index = prep.PrepIndex(tmp_path)
    assert len(index.pages) == 2
    assert index.pages[0].glyphs[0].class_name == "noteheadBlack"


def test_the_split_is_by_source_and_page_not_by_render(tmp_path):
    # The same source page rendered under two faces must land on the SAME
    # side of the split, or the identical engraved content is in train
    # and in val at once. split_of() takes no render/face argument at
    # all, so this pins that the split cannot leak render identity in:
    # two different (render_id, face) pairs for the same (source_id,
    # page_index) must agree.
    a = prep.split_of("src_a", 3, seed=7)
    b = prep.split_of("src_a", 3, seed=7)
    assert a == b

    _write_page(tmp_path, "r_a_ms4_Bravura_v0", "src_a", 3, face="ms4/Bravura")
    _write_page(tmp_path, "r_a_ms3_Emmentaler_v1", "src_a", 3, face="ms3/Emmentaler")
    index = prep.PrepIndex(tmp_path)
    assert {page.face for page in index.pages} == {"ms4/Bravura", "ms3/Emmentaler"}
    splits = {prep.split_of(page.source_id, page.page_index, seed=7)
              for page in index.pages}
    assert len(splits) == 1


def test_the_split_covers_all_three_buckets(tmp_path):
    seen = {prep.split_of(f"src_{i}", j, seed=7)
            for i in range(20) for j in range(20)}
    assert seen == {"train", "val", "test"}


def test_the_vocabulary_is_62_classes_and_excludes_the_unreachable_two():
    assert len(prep.VOCABULARY) == 62
    assert "fine" not in prep.VOCABULARY
    assert "toCoda" not in prep.VOCABULARY
    assert "stem" not in prep.VOCABULARY
    assert prep.CLASS_INDEX["brace"] == 0


def test_vocabulary_is_derived_from_class_names_minus_unreachable():
    from generate import vocabulary as sw_vocabulary

    expected = [name for name in sw_vocabulary.CLASS_NAMES
                if name not in sw_vocabulary.UNREACHABLE]
    assert prep.VOCABULARY == expected


def test_a_multi_root_index_concatenates_and_keeps_the_split_stable(tmp_path):
    # Training on the clean and the degraded export together is only
    # sound because `split_of` keys on (source_id, page_index): the same
    # engraved page must land in the same bucket in BOTH roots, so a page
    # held out of one is held out of all of them. This stages the same
    # page under two roots — with DIFFERENT render ids, as the two real
    # exports have — and requires exactly that.
    clean = tmp_path / "clean"
    degraded = tmp_path / "degraded"
    # src_0 is chosen because its two render ids DO fall in
    # different buckets under render-id keying (train vs test),
    # which is what makes the assertion below discriminating.
    _write_page(clean, "src_0_ms4_Bravura_v0", "src_0", 0)
    _write_page(degraded, "src_0_ms4_Bravura_v0_frozen", "src_0", 0)

    single = prep.PrepIndex(clean)
    both = prep.PrepIndex([clean, degraded])
    assert len(single.pages) == 1
    assert len(both.pages) == 2
    # Roots in the order given, pages sorted within each.
    assert [p.render_id for p in both.pages] == [
        "src_0_ms4_Bravura_v0", "src_0_ms4_Bravura_v0_frozen",
    ]
    # The load-bearing property. Keyed on the render id instead — which
    # the degraded export really did write into `source_id` until
    # 2026-08-18 — these two would split independently and the same
    # engraving would sit on both sides of the boundary.
    splits = {prep.split_of(p.source_id, p.page_index, 0) for p in both.pages}
    assert len(splits) == 1, "the same page landed in two different splits"
    assert len({prep.split_of(p.render_id, p.page_index, 0)
                for p in both.pages}) == 2, (
        "the fixture must be one where render-id keying WOULD disagree, "
        "or this proves nothing")
    # `root` still names something, for callers and log lines that
    # predate multi-root support.
    assert both.root == clean
