"""Turns a `prep.PrepIndex` into the tiles and CenterNet-style targets the
detector trains on: fixed-size image crops plus a per-tile heatmap /
offset / geom / mask stack, and a rarity-weighted sampler so pages
carrying a rare class are drawn far more than their share of pages would
otherwise give them (§3.2 R3 — a 600-page sample of the real dataset has
`noteheadBlack` 55,675 times and the rarest class 16 times).
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset

from . import prep


def tile_origins(extent: int, tile: int, overlap: int) -> list[int]:
    """Mirrors `OMRTiling.origins` in
    `Tests/SheetMusicTests/Helpers/OMRTiling.swift` exactly. Deliberately
    re-implemented on both sides of the Swift/Python boundary — it is
    integer arithmetic over sizes, with no image data in it —
    `test_tiling_matches_swift` pins the two to the same table.

    The last tile is flush with the far edge rather than short: the
    model is trained on one tile size, and a padded partial tile is an
    input distribution it never saw.
    """
    if extent <= tile:
        return [0]
    step = max(1, tile - overlap)
    result: list[int] = []
    origin = 0
    while origin + tile < extent:
        result.append(origin)
        origin += step
    result.append(extent - tile)
    return result


def gaussian_radius(det_size: tuple[float, float], min_overlap: float = 0.7) -> float:
    """CenterNet's radius: the largest blur that still leaves a box of
    this size overlapping the truth by `min_overlap`."""
    height, width = det_size
    b1 = height + width
    c1 = width * height * (1 - min_overlap) / (1 + min_overlap)
    r1 = (b1 - math.sqrt(max(0.0, b1 ** 2 - 4 * c1))) / 2
    b2 = 2 * (height + width)
    c2 = (1 - min_overlap) * width * height
    r2 = (b2 - math.sqrt(max(0.0, b2 ** 2 - 16 * c2))) / 8
    a3 = 4 * min_overlap
    b3 = -2 * min_overlap * (height + width)
    c3 = (min_overlap - 1) * width * height
    r3 = (b3 + math.sqrt(max(0.0, b3 ** 2 - 4 * a3 * c3))) / (2 * a3)
    return max(0.0, min(r1, r2, r3))


def _draw_gaussian(channel: np.ndarray, cx: int, cy: int, radius: int, sigma: float) -> None:
    """Splats a 2D Gaussian of the given `sigma` centered at grid cell
    (cx, cy) into `channel`, combined with whatever is already there via
    elementwise maximum — so two glyphs of the same class whose Gaussians
    overlap don't cancel each other's peaks."""
    height, width = channel.shape
    left = min(cx, radius)
    right = min(width - cx, radius + 1)
    top = min(cy, radius)
    bottom = min(height - cy, radius + 1)
    if left + right <= 0 or top + bottom <= 0:
        return
    ys = np.arange(-top, bottom, dtype=np.float32).reshape(-1, 1)
    xs = np.arange(-left, right, dtype=np.float32).reshape(1, -1)
    gaussian = np.exp(-(xs * xs + ys * ys) / (2 * sigma * sigma))
    region = channel[cy - top:cy + bottom, cx - left:cx + right]
    np.maximum(region, gaussian, out=region)


def _load_tile_image(png_path: Path, ox: int, oy: int, tile: int) -> np.ndarray:
    """Crops a `tile`x`tile` window at (ox, oy) out of the page PNG,
    normalized to [0, 1]. Pages narrower/shorter than one tile (only
    possible for the sole tile of a page smaller than `tile`, per
    `tile_origins`) are zero-padded on the right/bottom rather than
    resized, so the crop always matches the trained input size."""
    with Image.open(png_path) as im:
        arr = np.asarray(im.convert("L"), dtype=np.float32) / 255.0
    canvas = np.zeros((tile, tile), dtype=np.float32)
    height, width = arr.shape
    x1 = min(ox + tile, width)
    y1 = min(oy + tile, height)
    dst_w, dst_h = x1 - ox, y1 - oy
    if dst_w > 0 and dst_h > 0:
        canvas[0:dst_h, 0:dst_w] = arr[oy:y1, ox:x1]
    return canvas


def _class_frequencies(pages: list[prep.PrepPage]) -> dict[str, int]:
    """How many glyph instances of each class appear across `pages`."""
    freq: dict[str, int] = {}
    for page in pages:
        for glyph in page.glyphs:
            freq[glyph.class_name] = freq.get(glyph.class_name, 0) + 1
    return freq


def _page_rarity_weight(page: prep.PrepPage, freq: dict[str, int]) -> float:
    """1 / (rarest class's frequency among the classes this page
    contains) — a page carrying even one instance of a rare class is
    weighted the same as if the whole page were that rare class."""
    classes = {glyph.class_name for glyph in page.glyphs}
    if not classes:
        return 0.0
    # A class absent from the train split entirely (only possible for a
    # page outside the train split whose class never appears in train)
    # is treated as maximally rare rather than raising.
    min_freq = min(freq.get(c, 1) for c in classes)
    return 1.0 / min_freq


class SymbolTiles(Dataset):
    """One item per (page, tile) pair in `split`: a `tile`x`tile` image
    crop plus its CenterNet targets at output stride `stride`.

    `weights` (one entry per tile, aligned with `__len__`) is meant to be
    passed straight to `torch.utils.data.WeightedRandomSampler` — every
    tile of a page shares that page's rarity weight, computed once from
    class frequencies over the whole index's train split (not just this
    instance's `split`), so the weighting doesn't shift depending on
    which split happens to be loaded.
    """

    def __init__(self, index: prep.PrepIndex, split: str, tile: int = 384,
                 overlap: int = 64, stride: int = 4, seed: int = 0):
        self.tile = tile
        self.overlap = overlap
        self.stride = stride
        self.split = split
        self.pages: list[prep.PrepPage] = [
            page for page in index.pages
            if prep.split_of(page.source_id, page.page_index, seed) == split
        ]

        self.tiles: list[tuple[int, int, int]] = []
        for page_idx, page in enumerate(self.pages):
            xs = tile_origins(page.image.width_px, tile, overlap)
            ys = tile_origins(page.image.height_px, tile, overlap)
            for y in ys:
                for x in xs:
                    self.tiles.append((page_idx, x, y))
        self.tile_page: list[int] = [t[0] for t in self.tiles]

        train_pages = [
            page for page in index.pages
            if prep.split_of(page.source_id, page.page_index, seed) == "train"
        ]
        freq = _class_frequencies(train_pages)
        page_weight = [_page_rarity_weight(page, freq) for page in self.pages]
        self.weights = torch.tensor(
            [page_weight[page_idx] for page_idx in self.tile_page],
            dtype=torch.double)

    def __len__(self) -> int:
        return len(self.tiles)

    def __getitem__(self, idx: int):
        page_idx, ox, oy = self.tiles[idx]
        page = self.pages[page_idx]
        grid = self.tile // self.stride
        num_classes = len(prep.VOCABULARY)

        image = _load_tile_image(page.png_path, ox, oy, self.tile)
        heatmap = np.zeros((num_classes, grid, grid), dtype=np.float32)
        offset = np.zeros((2, grid, grid), dtype=np.float32)
        geom = np.zeros((4, grid, grid), dtype=np.float32)
        mask = np.zeros((1, grid, grid), dtype=np.float32)

        scale = page.image.staff_space_px
        for glyph in page.glyphs:
            cx, cy = glyph.center_px
            lx, ly = cx - ox, cy - oy
            if not (0 <= lx < self.tile and 0 <= ly < self.tile):
                continue
            fx, fy = lx / self.stride, ly / self.stride
            ix, iy = int(math.floor(fx)), int(math.floor(fy))
            if not (0 <= ix < grid and 0 <= iy < grid):
                continue

            cls = prep.CLASS_INDEX[glyph.class_name]
            det_size = (glyph.rendered_size_px / self.stride,
                        glyph.advance_px / self.stride)
            radius = max(0, int(round(gaussian_radius(det_size))))
            sigma = (2 * radius + 1) / 6
            _draw_gaussian(heatmap[cls], ix, iy, radius, sigma)

            ox_glyph, oy_glyph = glyph.origin_px
            offset[0, iy, ix] = fx - ix
            offset[1, iy, ix] = fy - iy
            geom[0, iy, ix] = (ox_glyph - cx) / scale
            geom[1, iy, ix] = (oy_glyph - cy) / scale
            geom[2, iy, ix] = glyph.advance_px / scale
            geom[3, iy, ix] = glyph.rendered_size_px / scale
            mask[0, iy, ix] = 1.0

        return (
            torch.from_numpy(image).unsqueeze(0),
            torch.from_numpy(heatmap),
            torch.from_numpy(offset),
            torch.from_numpy(geom),
            torch.from_numpy(mask),
        )
