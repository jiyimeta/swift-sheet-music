"""Do stacked 16th / 32nd beams survive the degradation chain as separate
slabs, or do they fuse?

A fused pair reads as ONE beam level downstream, silently turning every
16th into an 8th, so this decides whether the raster beam detector needs
a de-fusion step -- the most expensive optional piece of P3b. Method:
find truth beam pairs that overlap in x and are vertically adjacent,
sample the raster along the midline of the gap between them, and count a
pair as fused when that midline is mostly inked.

Usage (from the repo root):

    OMR_DATA_ROOT=~/Datasets/sheet-music-omr/v2 \\
        Training/.venv/bin/python Training/probes/measure_beam_fusion.py 60
    OMR_DATA_ROOT=... Training/.venv/bin/python \\
        Training/probes/measure_beam_fusion.py 60 degraded

Memory: one page live at a time.
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
from probes.measure_staff_ink import otsu_mask  # noqa: E402

PROFILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                       "generate", "profiles", "scanner.toml")

#: A gap is judged closed when at least this fraction of the samples
#: along its midline are inked.
CLOSED_FRACTION = 0.8


def _edges(beam, x):
    return (beam["top_slope"] * x + beam["top_intercept"],
            beam["bot_slope"] * x + beam["bot_intercept"])


def stacked_pairs(beams, sp):
    """(x0, x1, gap midline y, gap size) for every truth beam pair that
    overlaps in x and whose facing edges are less than one staff space
    apart -- the stacked-beam geometry at risk of fusing."""
    out = []
    for i, a in enumerate(beams):
        for b in beams[i + 1:]:
            lo, hi = max(a["x0"], b["x0"]), min(a["x1"], b["x1"])
            if hi - lo < 1.0:
                continue
            mid = (lo + hi) / 2
            a_top, a_bot = _edges(a, mid)
            b_top, b_bot = _edges(b, mid)
            # Whichever beam is on top, the gap is between the lower
            # beam's top edge and the upper beam's bottom edge.
            gap = a_bot - b_top if a_bot > b_top else b_bot - a_top
            y_mid = ((a_bot + b_top) / 2 if a_bot > b_top
                     else (b_bot + a_top) / 2)
            if 0 < gap < sp:
                out.append((lo, hi, y_mid, gap))
    return out


def main(sample: int, degraded: bool) -> None:
    root = os.path.expanduser(os.environ["OMR_DATA_ROOT"])
    dirs = sorted(d for d in os.listdir(root)
                  if os.path.isdir(os.path.join(root, d)) and d != "eval_frozen")
    random.Random(20260812).shuffle(dirs)

    stages = dg.load_profile(PROFILE) if degraded else None
    rng = np.random.default_rng(20260812)
    pairs_seen, pairs_closed, gaps_sp, pages = 0, 0, [], 0

    for d in dirs[:sample]:
        p = os.path.join(root, d)
        for name in sorted(os.listdir(p)):
            if not name.endswith(".labels.json"):
                continue
            with open(os.path.join(p, name)) as fh:
                labels = json.load(fh)
            if not labels.get("beams"):
                continue
            png = os.path.join(p, labels["image"]["file"])
            if not os.path.exists(png):
                continue
            sp = lg.staff_spacing_pt([y for _, _, y in lg.truth_lines(labels)])
            if sp is None:
                continue
            pairs = stacked_pairs(labels["beams"], sp)
            if not pairs:
                continue
            with Image.open(png) as im:
                img = np.asarray(im.convert("L"), dtype=np.uint8)
            h_map = np.eye(3)
            if stages is not None:
                img, h_map = dg.apply_chain(img, stages, rng)
            mask = otsu_mask(img)
            del img
            pages += 1

            dpi = labels["image"]["dpi"]
            page_h = labels["page"]["height_pt"]
            scale = dpi / 72.0
            for x0, x1, y_mid, gap in pairs:
                pairs_seen += 1
                gaps_sp.append(gap / sp)
                inked, samples = 0, 0
                for k in range(9):
                    x_pt = x0 + (x1 - x0) * (k + 0.5) / 9
                    px, py = lg.compose(h_map, x_pt * scale,
                                        (page_h - y_mid) * scale)
                    xi, yi = int(round(px)), int(round(py))
                    if 0 <= yi < mask.shape[0] and 0 <= xi < mask.shape[1]:
                        samples += 1
                        inked += bool(mask[yi, xi])
                if samples and inked / samples >= CLOSED_FRACTION:
                    pairs_closed += 1
            del mask

    tag = "degraded" if degraded else "clean"
    rate = pairs_closed / pairs_seen if pairs_seen else 0.0
    gaps_sp.sort()
    med = gaps_sp[len(gaps_sp) // 2] if gaps_sp else float("nan")
    print(f"[beam-fusion][{tag}] pages={pages} stackedPairs={pairs_seen} "
          f"fused={pairs_closed} fusionRate={rate:.4f} medianGap={med:.3f}sp")


if __name__ == "__main__":
    main(int(sys.argv[1]), "degraded" in sys.argv[2:])
