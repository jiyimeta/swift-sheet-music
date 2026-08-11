"""Pure geometry helpers shared by the raster measurement probes.

Kept separate from the sweeps so they can be unit-tested without a
dataset on disk -- the sweeps themselves need ~750MB of PNGs.
"""

import numpy as np


def truth_lines(labels, min_len_pt: float = 40.0):
    """(x0 pt, x1 pt, y pt) for every long horizontal path, deduplicated
    by y, with each line's segments unioned into one span.

    One staff line reaches the labels as 1-10 separate segments (measured
    on v2), so a caller counting segments would over-count lines by up to
    10x. The SPAN, not a midpoint, is what callers need: a probe walking
    the raster along a line has to stay inside the line's own extent, or
    the page margins on either side are counted as breaks in the ink --
    which is exactly the artifact that made the first run of
    `measure_staff_ink` report a 7.6-space median gap on a clean raster.

    Both endpoints also matter geometrically: a degradation rotation
    about the page centre moves y by an amount that depends on x, so a
    line's two ends land on different rows and a caller must interpolate
    between them rather than evaluate at one x.
    """
    by_y: dict[float, list[tuple[float, float]]] = {}
    for p in labels["paths"]:
        if p["kind"] != "horizontal":
            continue
        x0, y0, x1, _ = p["rect_pt"]
        if x1 - x0 < min_len_pt:
            continue
        by_y.setdefault(round(y0, 3), []).append((x0, x1))
    return sorted((min(s[0] for s in spans), max(s[1] for s in spans), y)
                  for y, spans in by_y.items())


def staff_spacing_pt(ys):
    """Median gap between adjacent staff-line y's, ignoring the large
    between-staff gaps. Returns None when there is no staff.

    The 30pt ceiling is above every measured within-staff spacing on v2
    (4.5-6.0pt) with wide margin, and far below any between-staff gap."""
    ys = sorted(ys)
    gaps = sorted(g for g in (ys[i] - ys[i - 1] for i in range(1, len(ys)))
                  if 0 < g < 30)
    return gaps[len(gaps) // 2] if gaps else None


def compose(h: np.ndarray, x: float, y: float):
    """Apply a 3x3 homogeneous transform to a point."""
    v = h @ np.array([x, y, 1.0])
    return (v[0] / v[2], v[1] / v[2])
