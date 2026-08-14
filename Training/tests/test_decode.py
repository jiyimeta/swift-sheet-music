import json
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from model import dataset, decode, prep


def _write_page(root: Path, render_id: str, source_id: str, page_index: int,
                 glyphs: list[dict], width_px: int = 100, height_px: int = 80,
                 staff_space_px: float = 12.0,
                 face: str = "ms4/Bravura") -> None:
    """Mirrors test_dataset.py's helper of the same name — kept local
    (not imported) so this file doesn't reach into another test module's
    private helper, matching this repo's existing per-file convention
    (test_prep.py and test_dataset.py each define their own copy too)."""
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


def test_decode_recovers_a_planted_peak():
    hm = np.zeros((2, 8, 8), np.float32)
    hm[1, 3, 4] = 0.9
    off = np.zeros((2, 8, 8), np.float32)
    off[:, 3, 4] = (0.25, 0.5)
    geom = np.zeros((4, 8, 8), np.float32)
    geom[:, 3, 4] = (-0.5, 0.0, 1.0, 0.75)
    dets = decode.decode_heads(hm, off, geom, staff_space_px=12,
                               threshold=0.3, top_k=10)
    assert len(dets) == 1
    d = dets[0]
    assert d.class_index == 1
    # cell (4,3) at stride 4 plus the sub-pixel offset
    assert d.center == pytest.approx((17.0, 14.0))
    # origin = center + geom[:2] * staff_space_px
    assert d.origin == pytest.approx((11.0, 14.0))
    assert d.advance == pytest.approx(12.0)


def test_decode_suppresses_a_neighbouring_cell_of_the_same_class():
    # Two cells of the SAME class, one cell apart, both inside each
    # other's 3x3 neighbourhood: only the higher-scoring one may survive.
    # Skipping the NMS step and going straight to threshold/top-K would
    # keep BOTH — they both clear 0.3 — so this is what pins the 3x3
    # max-pool step specifically, not just thresholding.
    hm = np.zeros((1, 8, 8), np.float32)
    hm[0, 3, 4] = 0.9
    hm[0, 3, 5] = 0.5
    off = np.zeros((2, 8, 8), np.float32)
    geom = np.zeros((4, 8, 8), np.float32)
    dets = decode.decode_heads(hm, off, geom, staff_space_px=12,
                               threshold=0.3, top_k=10)
    assert len(dets) == 1
    assert dets[0].score == pytest.approx(0.9)
    # the survivor is the (3, 4) peak, not (3, 5)
    assert dets[0].center == pytest.approx((16.0, 12.0))


def test_decode_returns_nothing_below_the_threshold():
    hm = np.zeros((1, 8, 8), np.float32)
    hm[0, 3, 4] = 0.2
    off = np.zeros((2, 8, 8), np.float32)
    geom = np.zeros((4, 8, 8), np.float32)
    dets = decode.decode_heads(hm, off, geom, staff_space_px=12,
                               threshold=0.3, top_k=10)
    assert dets == []


def test_decode_round_trips_dataset_encoding(tmp_path):
    # Nothing else pins decode.decode_heads to dataset.SymbolTiles's
    # encoding — the other three tests above plant hand-written hm/off/
    # geom arrays, and decode.py's own docstring claim that it is "the
    # literal inverse of SymbolTiles.__getitem__" is unverified by
    # anything that runs. Close that gap directly: build a real tile
    # via the real encoder, decode the heads it produced, and check
    # every one of the four planted quantities survives the round trip
    # — not just the centre, since class_index/center alone would still
    # pass with `advance` and `rendered_size` swapped (both are plain
    # floats at this glyph's staff_space_px).
    #
    # Deliberately non-round numbers and a nonzero sub-pixel remainder in
    # BOTH x and y, so the offset and geom channels are all genuinely
    # exercised (not just "encodes/decodes a multiple of stride").
    center_px = (41.5, 60.25)
    origin_px = (34.0, 60.25)
    advance_px = 13.5
    rendered_size_px = 9.25
    staff_space_px = 12.0

    # seed=0 puts "src_a"/page 0 in the train split — the same combo
    # test_dataset.py's own single-glyph tests rely on.
    _write_page(tmp_path, "r_a", "src_a", 0, [{
        "class": "noteheadBlack", "center_px": list(center_px),
        "origin_px": list(origin_px), "advance_px": advance_px,
        "rendered_size_px": rendered_size_px,
    }], staff_space_px=staff_space_px)
    index = prep.PrepIndex(tmp_path)
    ds = dataset.SymbolTiles(index, "train", seed=0)
    assert len(ds) == 1
    _image, hm, off, geom, _mask = ds[0]

    dets = decode.decode_heads(hm.numpy(), off.numpy(), geom.numpy(),
                               staff_space_px=staff_space_px,
                               threshold=0.5, top_k=10, stride=ds.stride)
    assert len(dets) == 1
    d = dets[0]
    assert d.class_index == prep.CLASS_INDEX["noteheadBlack"]

    # Tolerance: the encoding stores the EXACT fractional remainder
    # (fx - ix) as the offset target, so decode = (ix + offset) * stride
    # is algebraically the identity fx * stride = lx, not an
    # approximation — quantization only happens at the CELL level
    # (which cell owns the glyph), never within a cell. The only error
    # source is float32 round-trip through subtraction/division/
    # multiplication/addition. Measured empirically for this exact
    # fixture: max residual 2.4e-7 px (on rendered_size_px). 1e-3 is
    # three orders of magnitude above that measured noise floor while
    # still being far tighter than any real bug in this chain would
    # produce (a dropped staff_space_px multiply or a swapped geom
    # channel misses by whole pixels, not fractions of a micro-pixel).
    tol = 1e-3
    assert d.center == pytest.approx(center_px, abs=tol)
    assert d.origin == pytest.approx(origin_px, abs=tol)
    assert d.advance == pytest.approx(advance_px, abs=tol)
    assert d.rendered_size == pytest.approx(rendered_size_px, abs=tol)
