import json
from pathlib import Path

import numpy as np
import pytest
import torch
from PIL import Image

from model import augment, dataset, prep


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


def test_the_tile_image_is_the_page_window_normalized(tmp_path):
    # The image channel had NO test at all: every existing case here
    # asserts on the heatmap / offset / geom / mask, so an implementation
    # that returned the wrong window — or the right window off by an
    # offset, or unnormalized — went uncaught. This pins the pixels.
    png = tmp_path / "page.png"
    width, height = 40, 30
    # A gradient, so a wrong window or a transposed crop is visible in
    # the values. A constant-gray fixture (what _write_page makes) cannot
    # tell any of those apart.
    image = Image.new("L", (width, height))
    image.putdata([(x * 7 + y * 3) % 256 for y in range(height) for x in range(width)])
    image.save(png)
    source = np.asarray(image, dtype=np.float32) / 255.0

    tile = 16
    for ox, oy in [(0, 0), (8, 4), (24, 14)]:
        got = dataset._load_tile_image(png, ox, oy, tile)
        assert got.shape == (tile, tile)
        assert got.dtype == np.float32
        expected = source[oy:oy + tile, ox:ox + tile]
        assert np.array_equal(got, expected), f"window at ({ox}, {oy})"
        # And the values really are in [0, 1] — an unnormalized crop
        # would pass an array_equal against an unnormalized expectation
        # only if BOTH were wrong, so check the range independently.
        assert 0.0 <= got.min() and got.max() <= 1.0
        assert got.max() > 0.0


def test_a_page_smaller_than_the_tile_is_zero_padded_not_resized(tmp_path):
    # tile_origins returns [0] for a page smaller than the tile, so the
    # single crop runs off the page on the right and bottom. Those pixels
    # must be ZERO-padded — the model is trained at one input size and a
    # resized page is a distribution it never sees.
    png = tmp_path / "small.png"
    width, height = 10, 6
    image = Image.new("L", (width, height), color=255)
    image.save(png)

    tile = 16
    got = dataset._load_tile_image(png, 0, 0, tile)
    assert got.shape == (tile, tile)
    # The page's own area came through at full value...
    assert np.array_equal(got[0:height, 0:width], np.ones((height, width), dtype=np.float32))
    # ...and everything outside it is exactly zero, in both directions.
    assert got[height:, :].max() == 0.0
    assert got[:, width:].max() == 0.0
    # A resize would have filled the whole tile with 1.0 — assert it did
    # not, so this case cannot pass against a resizing implementation.
    assert got.mean() < 1.0


def test_augmentation_is_refused_outside_the_train_split(tmp_path):
    # An augmented validation loss is not comparable across epochs, and
    # the checkpoint is selected by comparing exactly that. Refuse rather
    # than trust the caller: nothing downstream could tell an augmented
    # val loss from a worse model.
    prep_root = tmp_path / "prep"
    _write_page(prep_root, "r_0", "src_0", 0, [_glyph("noteheadBlack", (30.0, 30.0))])
    _write_page(prep_root, "r_1", "src_10", 0, [_glyph("noteheadBlack", (30.0, 30.0))])
    index = prep.PrepIndex(prep_root)

    cfg = augment.PhotometricAugment()
    # train accepts it...
    dataset.SymbolTiles(index, "train", tile=128, overlap=32, seed=0, augment=cfg)
    # ...val and test do not.
    for split in ("val", "test"):
        with pytest.raises(ValueError, match="train-only"):
            dataset.SymbolTiles(index, split, tile=128, overlap=32, seed=0, augment=cfg)
    # And passing nothing is always fine.
    dataset.SymbolTiles(index, "val", tile=128, overlap=32, seed=0)


def test_photometric_augmentation_moves_no_ink_and_no_target(tmp_path):
    # The reason this augmentation is photometric-ONLY: the four target
    # planes are geometry, built once from the label, and nothing here
    # transforms them. So an op that MOVED the image would silently train
    # the geometry heads against the wrong answer — no crash, no counter.
    #
    # Asserting only "targets unchanged" would not catch that: the targets
    # are unchanged under a geometric op too. So this also locates the
    # ink in the augmented image and requires its centroid to stay put.
    # A shift of even one pixel fails it.
    png = _write_page(tmp_path, "r_0", "src_0", 0,
                      [_glyph("noteheadBlack", (40.0, 40.0), origin_px=(34.0, 40.0))],
                      width_px=100, height_px=80)
    # Draw a symmetric dark block well inside the page, so a blur cannot
    # move its centroid by clipping it against an edge.
    image = np.full((80, 100), 230, dtype=np.uint8)
    image[34:46, 34:46] = 20
    Image.fromarray(image).save(png)

    index = prep.PrepIndex(tmp_path)
    # Noise and speckle are off: both perturb a centroid by construction,
    # so leaving them on would force a tolerance loose enough to admit a
    # real shift.
    cfg = augment.PhotometricAugment(
        contrast_p=1.0, contrast_gain=(1.6, 1.6), contrast_bias=(0.05, 0.05),
        gamma_p=1.0, gamma=(1.8, 1.8), blur_p=1.0, blur_sigma=(0.9, 0.9),
        noise_p=0.0, speckle_p=0.0,
    )
    plain = dataset.SymbolTiles(index, "train", tile=128, overlap=32, seed=0)
    augmented = dataset.SymbolTiles(index, "train", tile=128, overlap=32, seed=0,
                                     augment=cfg)
    assert len(plain) == len(augmented) == 1

    a_image, *a_targets = plain[0]
    b_image, *b_targets = augmented[0]

    # It really augmented something.
    assert not torch.equal(a_image, b_image), "the image was not augmented"

    # Targets are bit-identical.
    for name, a, b in zip(["heatmap", "offset", "geom", "mask"], a_targets, b_targets):
        assert torch.equal(a, b), f"{name} changed under a photometric augmentation"
    # ...and they are not two all-zero planes.
    assert float(a_targets[0].max()) > 0.0
    assert float(a_targets[3].sum()) > 0.0

    def ink_centroid(t: torch.Tensor) -> tuple[float, float]:
        # Ink is dark, so weight by (1 - value) and keep only what is
        # clearly darker than paper.
        arr = 1.0 - t[0].numpy()
        arr = np.where(arr > 0.5 * arr.max(), arr, 0.0)
        total = arr.sum()
        assert total > 0, "no ink found — the fixture is vacuous"
        ys, xs = np.mgrid[0:arr.shape[0], 0:arr.shape[1]]
        return float((xs * arr).sum() / total), float((ys * arr).sum() / total)

    ax, ay = ink_centroid(a_image)
    bx, by = ink_centroid(b_image)
    assert abs(ax - bx) < 0.25, f"ink moved in x: {ax} -> {bx}"
    assert abs(ay - by) < 0.25, f"ink moved in y: {ay} -> {by}"
