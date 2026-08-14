import json
from pathlib import Path

import pytest
import torch
from PIL import Image

from model import dataset, prep


def _write_page(root: Path, render_id: str, source_id: str, page_index: int,
                 glyphs: list[dict], width_px: int = 100, height_px: int = 80,
                 staff_space_px: float = 12.0,
                 face: str = "ms4/Bravura") -> Path:
    """Writes one prep page: the `.prep.json` sidecar plus a real
    (solid-gray) `.prep.png` beside it, so `SymbolTiles.__getitem__` has
    an actual image to crop."""
    d = root / render_id
    d.mkdir(parents=True, exist_ok=True)
    png_name = f"page_{page_index}.prep.png"
    (d / f"page_{page_index}.prep.json").write_text(json.dumps({
        "schema": 1, "render_id": render_id, "source_id": source_id,
        "face": face, "page_index": page_index,
        "image": {"file": png_name, "width_px": width_px,
                  "height_px": height_px, "staff_space_px": staff_space_px,
                  "scale": 0.5, "source_width_px": width_px * 2,
                  "source_height_px": height_px * 2, "source_dpi": 300.0,
                  "deskew_degrees": 0.0},
        "glyphs": glyphs,
    }))
    Image.new("L", (width_px, height_px), color=200).save(d / png_name)
    return d / png_name


def _glyph(class_name: str, center_px: tuple[float, float],
           origin_px: tuple[float, float] | None = None,
           advance_px: float = 12.0, rendered_size_px: float = 9.0) -> dict:
    return {
        "class": class_name,
        "center_px": list(center_px),
        "origin_px": list(origin_px if origin_px is not None else center_px),
        "advance_px": advance_px,
        "rendered_size_px": rendered_size_px,
    }


def test_tiling_matches_swift():
    # Pinned against Tests/SheetMusicTests/Helpers/OMRTiling.swift's
    # OMRTilingTests. These two implementations exist on purpose (integer
    # arithmetic, no image data); this table is what keeps them equal.
    assert dataset.tile_origins(200, 384, 64) == [0]
    assert dataset.tile_origins(900, 384, 64) == [0, 320, 516]
    assert dataset.tile_origins(384, 384, 64) == [0]
    assert dataset.tile_origins(704, 384, 64) == [0, 320]


def test_a_glyph_becomes_a_peak_at_its_center(tmp_path):
    # One glyph at center (40, 60) with stride 4 puts the peak at (10, 15)
    # and the sub-pixel offset at exactly zero.
    _write_page(tmp_path, "r_a", "src_a", 0,
                [_glyph("noteheadBlack", (40.0, 60.0))])
    index = prep.PrepIndex(tmp_path)
    ds = dataset.SymbolTiles(index, "train", seed=0)
    assert len(ds) == 1
    _image, hm, off, _geom, _mask = ds[0]
    cls = prep.CLASS_INDEX["noteheadBlack"]
    assert hm[cls, 15, 10] == pytest.approx(1.0)
    assert off[:, 15, 10] == pytest.approx([0.0, 0.0])


def test_the_offset_head_carries_the_sub_pixel_remainder(tmp_path):
    # center (41.5, 60) → cell (10, 15), offset (0.375, 0.0) in cell units
    _write_page(tmp_path, "r_a", "src_a", 0,
                [_glyph("noteheadBlack", (41.5, 60.0))])
    index = prep.PrepIndex(tmp_path)
    ds = dataset.SymbolTiles(index, "train", seed=0)
    _image, _hm, off, _geom, _mask = ds[0]
    assert off[:, 15, 10] == pytest.approx([0.375, 0.0])


def test_geom_is_in_staff_space_units(tmp_path):
    # staff_space_px = 12, advance_px = 12 → geom[2] == 1.0, so the
    # regression target is scale-free and directly comparable to the
    # 0.25 sp origin budget.
    _write_page(tmp_path, "r_a", "src_a", 0,
                [_glyph("noteheadBlack", (40.0, 60.0), origin_px=(34.0, 60.0),
                        advance_px=12.0, rendered_size_px=9.0)],
                staff_space_px=12.0)
    index = prep.PrepIndex(tmp_path)
    ds = dataset.SymbolTiles(index, "train", seed=0)
    _image, _hm, _off, geom, _mask = ds[0]
    assert geom[2, 15, 10] == pytest.approx(1.0)
    # origin sits 6px to the left of center: (origin - center) / S == -0.5
    assert geom[0, 15, 10] == pytest.approx(-0.5)
    assert geom[1, 15, 10] == pytest.approx(0.0)
    # rendered_size_px / S == 9 / 12 == 0.75
    assert geom[3, 15, 10] == pytest.approx(0.75)


def test_only_the_positive_cells_are_masked_in(tmp_path):
    _write_page(tmp_path, "r_a", "src_a", 0,
                [_glyph("noteheadBlack", (40.0, 60.0))])
    index = prep.PrepIndex(tmp_path)
    ds = dataset.SymbolTiles(index, "train", seed=0)
    _image, _hm, _off, _geom, mask = ds[0]
    assert mask.sum() == 1


def test_a_glyph_outside_the_tile_is_not_a_target(tmp_path):
    # A page whose only glyph sits at (500, 500) yields an all-zero
    # heatmap for the tile at origin (0, 0) — a glyph belongs to the
    # tile that contains its CENTER and to no other, or the same glyph
    # is trained as a target from two crops with different offsets.
    _write_page(tmp_path, "r_a", "src_a", 0,
                [_glyph("noteheadBlack", (500.0, 500.0))],
                width_px=900, height_px=900)
    index = prep.PrepIndex(tmp_path)
    ds = dataset.SymbolTiles(index, "train", seed=0)
    # 900px at tile=384/overlap=64 tiles into 3x3 = 9 tiles; the first one
    # (in y-then-x iteration order) is the tile at origin (0, 0).
    assert ds.tiles[0] == (0, 0, 0)
    _image, hm, _off, _geom, mask = ds[0]
    assert float(hm.max()) == 0.0
    assert float(mask.sum()) == 0.0


def test_a_glyph_in_the_overlap_strip_is_a_target_in_both_tiles(tmp_path):
    # Deliberate, not a bug: exclusive tile ownership (OMRTiling.coreRange)
    # is an INFERENCE-time rule, so a detection made from two overlapping
    # crops isn't double-counted in the merge step. Training is a
    # different problem — each tile is an independent sample, and the
    # glyph is genuinely, fully visible in both crops. Suppressing the
    # target in whichever tile doesn't "own" it would teach the model to
    # NOT fire on symbols that happen to sit near a tile edge, which is
    # actively harmful. So a glyph in the overlap strip between two tiles
    # is a positive target in BOTH, each with its own local offset.
    #
    # 900px wide -> origins [0, 320, 516] (tile_origins(900, 384, 64)).
    # A glyph centred at page x=350 falls inside both tile 0's window
    # ([0, 384)) and tile 320's window ([320, 704)), with local x 350
    # and 30 respectively.
    _write_page(tmp_path, "r_a", "src_a", 0,
                [_glyph("noteheadBlack", (350.0, 60.0))],
                width_px=900, height_px=900)
    index = prep.PrepIndex(tmp_path)
    ds = dataset.SymbolTiles(index, "train", seed=0)

    def _recovered_x(item):
        _image, _hm, off, _geom, mask = item
        assert mask.sum() == 1.0
        row, col = (mask[0] == 1).nonzero(as_tuple=True)
        row, col = int(row[0]), int(col[0])
        return (col + float(off[0, row, col])) * ds.stride

    tile0 = ds[ds.tiles.index((0, 0, 0))]
    tile320 = ds[ds.tiles.index((0, 320, 0))]
    assert _recovered_x(tile0) == pytest.approx(350.0)
    assert _recovered_x(tile320) == pytest.approx(30.0)


def test_rare_classes_are_oversampled(tmp_path):
    # Two pages: one with 100 noteheadBlack, one with a single rest32nd.
    # Over many draws the rare page must appear far more often than its
    # 1/2 share of pages would give.
    dense_glyphs = [
        _glyph("noteheadBlack", (10.0 + i, 10.0)) for i in range(100)
    ]
    rare_glyphs = [_glyph("rest32nd", (10.0, 10.0))]
    # seed=0 puts both "src_dense"/0 and "src_rare"/0 in the train split;
    # "r_dense" sorts before "r_rare" so PrepIndex order is [dense, rare].
    _write_page(tmp_path, "r_dense", "src_dense", 0, dense_glyphs)
    _write_page(tmp_path, "r_rare", "src_rare", 0, rare_glyphs)
    index = prep.PrepIndex(tmp_path)
    ds = dataset.SymbolTiles(index, "train", seed=0)
    assert len(ds) == 2
    assert ds.tile_page == [0, 1]  # one tile per page, in page order

    generator = torch.Generator().manual_seed(0)
    sampler = torch.utils.data.WeightedRandomSampler(
        ds.weights, num_samples=2000, replacement=True, generator=generator)
    drawn = list(sampler)
    rare_draws = sum(1 for i in drawn if ds.tile_page[i] == 1)
    # naive share would be 1/2; the 100:1 rarity weighting should push
    # this far above it.
    assert rare_draws / len(drawn) > 0.8
