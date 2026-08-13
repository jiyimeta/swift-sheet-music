import json
from pathlib import Path

from model import prep


def _write_page(root: Path, render_id: str, source_id: str, page_index: int):
    d = root / render_id
    d.mkdir(parents=True, exist_ok=True)
    (d / f"page_{page_index}.prep.json").write_text(json.dumps({
        "schema": 1, "render_id": render_id, "source_id": source_id,
        "face": "ms4/Bravura", "page_index": page_index,
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

    _write_page(tmp_path, "r_a_ms4_Bravura_v0", "src_a", 3)
    _write_page(tmp_path, "r_a_ms3_Emmentaler_v1", "src_a", 3)
    index = prep.PrepIndex(tmp_path)
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
