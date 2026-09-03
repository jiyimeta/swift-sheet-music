"""Histogram the confidence split on one octave-clef class from a
`[mscz-clefcand]` dump: per vector clef of `--vector`, the best score of
the exact class and of its plain sibling in the neighbourhood, bucketed,
plus how many truths have NO clef candidate at all at the dump's τ.

Usage: clef_split_hist.py <log> [--vector clefF8va] [--radius 12]
"""
from __future__ import annotations

import argparse
from collections import Counter

from clef_table import CAND, LINE, family


def bucket(score: float) -> str:
    if score <= 0.0:
        return "0"
    edges = [0.02, 0.1, 0.2, 0.3, 0.5, 0.7, 1.01]
    lo = 0.0
    for hi in edges:
        if score < hi:
            return f"[{lo:.2f},{hi:.2f})"
        lo = hi
    return "?"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    parser.add_argument("--vector", default="clefF8va")
    parser.add_argument("--radius", type=float, default=12.0)
    args = parser.parse_args()
    base = family(args.vector)
    exact_hist = Counter()
    base_hist = Counter()
    joint = Counter()
    no_clef = 0
    n = 0
    with open(args.log, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.search(line)
            if not m or m.group("vector") != args.vector:
                continue
            n += 1
            cands = [(c.group("cls"), float(c.group("score")), float(c.group("dist")))
                     for c in CAND.finditer(m.group("cands"))
                     if float(c.group("dist")) <= args.radius]
            clefs = [c for c in cands if c[0].startswith("clef")]
            if not clefs:
                no_clef += 1
            e = max((c[1] for c in cands if c[0] == args.vector), default=0.0)
            b = max((c[1] for c in cands if c[0] == base), default=0.0)
            exact_hist[bucket(e)] += 1
            base_hist[bucket(b)] += 1
            joint[(e > 0.3, b > 0.3)] += 1
    print(f"vector={args.vector} n={n} no_clef_candidate_at_all={no_clef}")
    print(f"{'bucket':14s} {'exact':>6s} {'base':>6s}")
    for key in sorted(set(exact_hist) | set(base_hist)):
        print(f"{key:14s} {exact_hist[key]:6d} {base_hist[key]:6d}")
    print("joint (exact>τ, base>τ):", dict(joint))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
