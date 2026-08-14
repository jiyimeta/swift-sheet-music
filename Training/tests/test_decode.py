import numpy as np
import pytest

from model import decode


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
