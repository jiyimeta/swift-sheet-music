"""How badly does the scanner degradation chain break staff-line ink?

For every truth staff line, walk the raster along that line and record
the lengths of the GAPS in the ink. The resulting distribution is what
sets the raster stage's run-merge gap tolerance
(`RasterPage.staffLineGapToleranceInSpaces`): a tolerance below the p95
gap leaves lines fragmented, and `PDFImporter.detectStaves` positions
lines only from segments wider than `lineClusterWidthGate` = 50pt -- so a
fragmented line is a DROPPED line, not a slightly worse one.

Usage (from the repo root):

    OMR_DATA_ROOT=~/Datasets/sheet-music-omr/v2 \\
        Training/.venv/bin/python Training/probes/measure_staff_ink.py 40
    OMR_DATA_ROOT=... Training/.venv/bin/python \\
        Training/probes/measure_staff_ink.py 40 degraded

Memory: one page live at a time; every array is deleted before the next.
A previous sweep over this dataset that did not do this consumed 24GB.
"""

import json
import os
import random
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from generate import degrade as dg  # noqa: E402
from probes import label_geometry as lg  # noqa: E402

PROFILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                       "generate", "profiles", "scanner.toml")

#: Candidate merge tolerances, in staff spaces, scored below.
TOLERANCES = (0.0, 0.5, 1.0, 2.0, 3.0, 4.0, 6.0)

#: `PDFImporter.lineClusterWidthGate` -- a surviving piece narrower than
#: this is discarded downstream, so it does not count as a survival.
MIN_SEGMENT_PT = 50.0


def otsu_mask(img: np.ndarray) -> np.ndarray:
    """Global Otsu threshold; True is ink. Mirrors the Swift side's
    `RasterPage.otsuThreshold` so the two measure the same thing."""
    hist = np.bincount(img.ravel(), minlength=256).astype(np.float64)
    omega = np.cumsum(hist) / hist.sum()
    mu = np.cumsum(hist * np.arange(256)) / hist.sum()
    denom = omega * (1 - omega)
    denom[denom == 0] = 1e-12
    return img <= int(np.argmax((mu[-1] * omega - mu) ** 2 / denom))


def gaps_along(mask: np.ndarray, x0: float, row0: float,
               x1: float, row1: float, band: int):
    """Interior gap lengths (px) along one staff line.

    The walk stays strictly inside the line's own x span and the expected
    row is interpolated between its two mapped endpoints, so a rotation
    is followed rather than reported as breakage. A column counts as
    inked if ANY row within +/-band of the expected centre is inked --
    the line is only 1-3px thick at these dpis.

    Leading and trailing runs are dropped: outside the line there is no
    line, and counting the page margin as a gap is what made the first
    version of this probe report a 7.6-space median gap on a CLEAN
    raster.

    Returns `(start_x_px, length_px)` per gap.
    """
    xa, xb = int(round(min(x0, x1))), int(round(max(x0, x1)))
    xa = max(0, xa)
    xb = min(mask.shape[1] - 1, xb)
    if xb <= xa:
        return []
    out: list[tuple[int, int]] = []
    run, run_start, seen_ink = 0, xa, False
    for x in range(xa, xb + 1):
        t = (x - x0) / (x1 - x0) if x1 != x0 else 0.0
        row = int(round(row0 + (row1 - row0) * t))
        lo = max(0, row - band)
        hi = min(mask.shape[0], row + band + 1)
        inked = lo < hi and bool(mask[lo:hi, x].any())
        if inked:
            if run and seen_ink:
                out.append((run_start, run))
            run = 0
            seen_ink = True
        elif seen_ink:
            if run == 0:
                run_start = x
            run += 1
    return out


def longest_surviving_run(xa: int, xb: int, gaps, tol_px: float) -> int:
    """Longest contiguous stretch (px) left after breaking the line at
    every gap WIDER than `tol_px`.

    This, not the raw gap distribution, is the statistic the merge
    tolerance has to be chosen against: `PDFImporter.detectStaves`
    positions staff lines only from segments wider than
    `lineClusterWidthGate` = 50pt, so what matters is whether ONE
    surviving piece is still long enough, not how many small holes the
    line has."""
    breaks = sorted((start, start + length)
                    for start, length in gaps if length > tol_px)
    best, cursor = 0, xa
    for lo, hi in breaks:
        best = max(best, lo - cursor)
        cursor = max(cursor, hi)
    return max(best, xb - cursor)


def main(sample: int, degraded: bool) -> None:
    root = os.path.expanduser(os.environ["OMR_DATA_ROOT"])
    dirs = sorted(d for d in os.listdir(root)
                  if os.path.isdir(os.path.join(root, d)) and d != "eval_frozen")
    random.Random(20260812).shuffle(dirs)

    stages = dg.load_profile(PROFILE) if degraded else None
    rng = np.random.default_rng(20260812)
    per_dpi: dict[int, list[float]] = {}
    survived: dict[float, int] = {}
    lines_total = 0

    for d in dirs[:sample]:
        p = os.path.join(root, d)
        for name in sorted(os.listdir(p)):
            if not name.endswith(".labels.json"):
                continue
            with open(os.path.join(p, name)) as fh:
                labels = json.load(fh)
            png = os.path.join(p, labels["image"]["file"])
            if not os.path.exists(png):
                continue
            with Image.open(png) as im:
                img = np.asarray(im.convert("L"), dtype=np.uint8)
            h_map = np.eye(3)
            if stages is not None:
                img, h_map = dg.apply_chain(img, stages, rng)
            mask = otsu_mask(img)
            del img

            dpi = labels["image"]["dpi"]
            page_h = labels["page"]["height_pt"]
            lines = lg.truth_lines(labels)
            sp = lg.staff_spacing_pt([y for _, _, y in lines])
            if sp is None:
                del mask
                continue
            band = max(1, int(round(0.15 * sp * dpi / 72.0)))
            bucket = per_dpi.setdefault(dpi, [])
            scale = dpi / 72.0
            for x0_pt, x1_pt, y_pt in lines:
                row_px = (page_h - y_pt) * scale
                xa, ra = lg.compose(h_map, x0_pt * scale, row_px)
                xb, rb = lg.compose(h_map, x1_pt * scale, row_px)
                lines_total += 1
                gaps = gaps_along(mask, xa, ra, xb, rb, band)
                for _, length in gaps:
                    bucket.append(length * 72.0 / dpi / sp)
                lo_x = max(0, int(round(min(xa, xb))))
                hi_x = min(mask.shape[1] - 1, int(round(max(xa, xb))))
                span_px = hi_x - lo_x
                for tol in TOLERANCES:
                    longest = longest_surviving_run(
                        lo_x, hi_x, gaps, tol * sp * scale,
                    )
                    if span_px > 0 and longest >= 0.8 * span_px \
                            and longest * 72.0 / dpi >= MIN_SEGMENT_PT:
                        survived[tol] = survived.get(tol, 0) + 1
            del mask

    tag = "degraded" if degraded else "clean"
    for dpi in sorted(per_dpi):
        gaps = sorted(per_dpi[dpi])
        if not gaps:
            print(f"[staff-ink][{tag}] dpi={dpi} lines={lines_total} gaps=0")
            continue

        def q(f, g=gaps):
            return g[min(len(g) - 1, int(len(g) * f))]

        print(f"[staff-ink][{tag}] dpi={dpi} lines={lines_total} gaps={len(gaps)} "
              f"p50={q(.5):.3f}sp p95={q(.95):.3f}sp p99={q(.99):.3f}sp "
              f"max={gaps[-1]:.3f}sp")

    # The number the merge tolerance is actually chosen against: with the
    # line broken at every gap wider than the tolerance, does ONE piece
    # still cover 80% of the span and clear `lineClusterWidthGate`?
    print(f"[staff-ink][{tag}] survival lines={lines_total} " + " ".join(
        f"tol{tol}sp={survived.get(tol, 0) / max(1, lines_total):.4f}"
        for tol in TOLERANCES))


if __name__ == "__main__":
    main(int(sys.argv[1]), "degraded" in sys.argv[2:])
