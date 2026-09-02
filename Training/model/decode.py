"""Reference decode of `net.SymbolNet`'s three heads (heatmap
probabilities / offset / geom) into a list of `Detection`.

This is a REFERENCE, not the inference path. The shipped decode runs in
Swift — peak extraction, `geom` reconstruction, tile merging and the map
into page coordinates all happen there, so the exported model graph
stays trivially convertible (Core ML now, ONNX for Android later) and
both platforms decode the same way. This module exists so a later task
can compare the Swift decode against known numbers during Core ML
bring-up (planted heads in, `Detection`s out): it is written as the
clearest possible statement of the arithmetic, not as something
optimized, and its interface is deliberately small — one page's worth
of heads, no batching, no GPU.

`decode_heads` is the literal inverse of `dataset.SymbolTiles.__getitem__`:
that method encodes a glyph's local pixel position `(lx, ly)` as a grid
cell `(ix, iy) = floor(lx / stride), floor(ly / stride)` plus the
fractional remainder `offset = (lx / stride - ix, ly / stride - iy)` in
CELL units (no half-cell shift — the encoding has no notion of "cell
center"), and its `geom` in staff-space units relative to the
reconstructed center. Decoding undoes exactly that:
`center = (cell + offset) * stride`, `origin = center + geom[:2] *
staff_space_px`, `advance = geom[2] * staff_space_px`, `rendered_size =
geom[3] * staff_space_px`.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class Detection:
    """One decoded symbol, in the tile's local pixel space (the same
    units as `prep.Glyph.center_px` / `origin_px`), y-down.

    `origin` is the SMuFL registration point reconstructed from `geom`,
    not a box corner — see `prep.Glyph`'s docstring. `score` is the
    heatmap probability at the peak cell, post-NMS.
    """
    class_index: int
    score: float
    center: tuple[float, float]
    origin: tuple[float, float]
    advance: float
    rendered_size: float


def _nms(hm: np.ndarray) -> np.ndarray:
    """3x3 max-pool NMS, independently per class channel: a cell survives
    only if it is the maximum of its own 3x3 neighbourhood (which always
    includes the cell itself, so a strict local maximum always survives,
    and a tie survives on both sides). Suppressed cells come back as 0."""
    num_classes, height, width = hm.shape
    padded = np.pad(hm, ((0, 0), (1, 1), (1, 1)), mode="constant",
                     constant_values=-np.inf)
    pooled = np.full_like(hm, -np.inf)
    for dy in range(3):
        for dx in range(3):
            window = padded[:, dy:dy + height, dx:dx + width]
            pooled = np.maximum(pooled, window)
    return hm * (hm >= pooled)


def decode_heads(hm: np.ndarray, off: np.ndarray, geom: np.ndarray,
                  staff_space_px: float, threshold: float, top_k: int,
                  stride: int = 4) -> list["Detection"]:
    """`hm` is `(num_classes, H, W)` PER-CLASS PROBABILITY (post-sigmoid —
    matching what `net.ExportWrapper` emits; this function applies no
    sigmoid of its own). `off` is `(2, H, W)`, `geom` is `(4, H, W)`, both
    at the same `(H, W)` as `hm`. Order of operations, matching the
    CenterNet decode this net was trained against: 3x3 max-pool NMS on
    the heatmap, threshold (score > `threshold` survives), then keep the
    `top_k` highest-scoring survivors overall (not per class).

    Returns detections sorted by descending score.
    """
    peaks = _nms(hm)
    candidates: list[tuple[float, int, int, int]] = [
        (float(peaks[cls, iy, ix]), int(cls), int(iy), int(ix))
        for cls in range(hm.shape[0])
        for iy, ix in zip(*np.nonzero(peaks[cls] > threshold))
    ]
    candidates.sort(key=lambda c: c[0], reverse=True)

    dets: list[Detection] = []
    for score, cls, iy, ix in candidates[:top_k]:
        cx = (ix + float(off[0, iy, ix])) * stride
        cy = (iy + float(off[1, iy, ix])) * stride
        ox = cx + float(geom[0, iy, ix]) * staff_space_px
        oy = cy + float(geom[1, iy, ix]) * staff_space_px
        advance = float(geom[2, iy, ix]) * staff_space_px
        rendered_size = float(geom[3, iy, ix]) * staff_space_px
        dets.append(Detection(cls, score, (cx, cy), (ox, oy), advance, rendered_size))
    return dets
