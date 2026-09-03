"""Paired per-file A/B of two `.mscz` corpus sweeps (MSCZGroundTruthSweep
logs): for every file present in both, the raster `pitch%` and `dur%`
deltas, counted as better / worse / same with the summed points each way
— the shape the τ counterfactual and the clef-consensus A/B were read in.

Usage: corpus_ab.py <log-A> <log-B> [--mode raster] [--show 15]
"""
from __future__ import annotations

import argparse
import re
import sys

ROW = re.compile(r"\[mscz-(?P<mode>vector|raster)\]\[(?P<file>[^\]]*)\]\[SUMMARY\].*?"
                 r"pitch%=(?P<pitch>[\d.]+|n/a)%?.*?dur%=(?P<dur>[\d.]+|n/a)%?")


def read(path: str, mode: str) -> dict[str, tuple[float | None, float | None]]:
    out: dict[str, tuple[float | None, float | None]] = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = ROW.search(line)
            if not m or m.group("mode") != mode:
                continue
            def num(s: str) -> float | None:
                return None if s == "n/a" else float(s)
            out[m.group("file")] = (num(m.group("pitch")), num(m.group("dur")))
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log_a")
    parser.add_argument("log_b")
    parser.add_argument("--mode", default="raster")
    parser.add_argument("--show", type=int, default=15,
                        help="print the N largest movers each way")
    args = parser.parse_args()
    a = read(args.log_a, args.mode)
    b = read(args.log_b, args.mode)
    common = sorted(set(a) & set(b))
    if not common:
        print("no common files", file=sys.stderr)
        return 1
    print(f"mode={args.mode} A={len(a)} B={len(b)} common={len(common)} "
          f"onlyA={len(set(a) - set(b))} onlyB={len(set(b) - set(a))}")
    for idx, label in ((0, "pitch"), (1, "dur")):
        better = worse = same = 0
        gain = loss = 0.0
        deltas = []
        for file in common:
            va, vb = a[file][idx], b[file][idx]
            if va is None or vb is None:
                continue
            d = vb - va
            deltas.append((d, file, va, vb))
            if d > 0:
                better += 1
                gain += d
            elif d < 0:
                worse += 1
                loss += d
            else:
                same += 1
        vals_a = sorted(v[idx] for v in (a[f] for f in common) if v[idx] is not None)
        vals_b = sorted(v[idx] for v in (b[f] for f in common) if v[idx] is not None)
        p50 = lambda xs: xs[len(xs) // 2] if xs else float("nan")  # noqa: E731
        mean = lambda xs: sum(xs) / len(xs) if xs else float("nan")  # noqa: E731
        print(f"\n{label}: better={better} worse={worse} same={same} "
              f"+{gain:.0f}pt / {loss:.0f}pt  net {gain + loss:+.0f}pt")
        print(f"  {label}P50 {p50(vals_a) / 100:.4f} -> {p50(vals_b) / 100:.4f}   "
              f"{label}Mean {mean(vals_a) / 100:.4f} -> {mean(vals_b) / 100:.4f}")
        deltas.sort()
        for d, file, va, vb in deltas[: args.show]:
            if d < 0:
                print(f"  {d:+6.0f}  {va:5.0f} -> {vb:5.0f}  {file}")
        for d, file, va, vb in deltas[::-1][: args.show]:
            if d > 0:
                print(f"  {d:+6.0f}  {va:5.0f} -> {vb:5.0f}  {file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
