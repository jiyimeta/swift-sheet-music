"""Aggregate `[mscz-clefcand]` lines (MSCZGroundTruthSweep.clefProbe) into
the real-render clef table, and price decode rules offline.

Each line is one VECTOR clef (the truth, read from the typeset PDF) and the
raster candidates the detector placed within 12pt of it, each with the
heatmap score it was decoded at:

    [mscz-clefcand][<file>] page=N vector=clefF8va at=(x,y) \
        candidates=[clefF@0.412@0.3 clefF8va@0.201@0.6 ...]

Run the sweep under `OMR_DECODE_THRESHOLD=0.02` so the candidates include
what the shipped τ (0.30) discards; every rule below is then evaluated
from the same dump, with no re-run per rule:

    shipped   top-scoring candidate with score > τ           (per-class NMS,
                                                              no competition)
    famsum    candidates grouped by clef family (G / F / C / percussion);
              a family whose SUMMED score > τ wins, its argmax class is
              the prediction
    fammax    like `shipped` but the winning candidate's family is taken
              first and the argmax within that family is the prediction,
              accepting a per-class score down to τ/2 for the family
              winner

For every rule the outcome per vector clef is one of:

    exact     predicted class == vector class
    sibling   same family, different octave variant
    other     a clef of another family
    none      no candidate cleared the rule

Usage:
    clef_table.py <log> [--tau 0.30] [--radius 12]
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import Counter, defaultdict

LINE = re.compile(
    r"\[mscz-clefcand\]\[(?P<file>[^\]]*)\] page=(?P<page>\d+) "
    r"vector=(?P<vector>\S+) at=\((?P<x>[-\d.]+),(?P<y>[-\d.]+)\) "
    r"candidates=\[(?P<cands>[^\]]*)\]"
)
CAND = re.compile(r"(?P<cls>\S+?)@(?P<score>[\d.]+)@(?P<dist>[\d.]+)")

OCTAVE_SUFFIXES = ("15ma", "15mb", "8va", "8vb")


def family(cls: str) -> str:
    """`clefF8va` -> `clefF`; `clefPercussion` -> `clefPercussion`."""
    for suffix in OCTAVE_SUFFIXES:
        if cls.endswith(suffix):
            return cls[: -len(suffix)]
    return cls


def outcome(vector: str, predicted: str | None) -> str:
    if predicted is None:
        return "none"
    if predicted == vector:
        return "exact"
    if family(predicted) == family(vector):
        return "sibling"
    return "other"


def rule_shipped(cands: list[tuple[str, float, float]], tau: float) -> str | None:
    passing = [c for c in cands if c[1] > tau]
    if not passing:
        return None
    return max(passing, key=lambda c: c[1])[0]


def rule_famsum(cands: list[tuple[str, float, float]], tau: float) -> str | None:
    by_family: dict[str, list[tuple[str, float, float]]] = defaultdict(list)
    for c in cands:
        by_family[family(c[0])].append(c)
    best_family, best_sum = None, 0.0
    for fam, members in by_family.items():
        # One score per class (the best of that class in the neighbourhood),
        # then summed over the family's classes.
        per_class: dict[str, float] = {}
        for cls, score, _ in members:
            per_class[cls] = max(per_class.get(cls, 0.0), score)
        total = sum(per_class.values())
        if total > best_sum:
            best_family, best_sum = fam, total
    if best_family is None or best_sum <= tau:
        return None
    members = by_family[best_family]
    return max(members, key=lambda c: c[1])[0]


def rule_fammax(cands: list[tuple[str, float, float]], tau: float) -> str | None:
    passing = [c for c in cands if c[1] > tau / 2]
    if not passing:
        return None
    winner = max(passing, key=lambda c: c[1])
    if winner[1] <= tau:
        # Nothing clears τ on its own; the family may still, in sum.
        fam_members = [c for c in passing if family(c[0]) == family(winner[0])]
        if sum(c[1] for c in fam_members) <= tau:
            return None
    fam_members = [c for c in passing if family(c[0]) == family(winner[0])]
    return max(fam_members, key=lambda c: c[1])[0]


RULES = {"shipped": rule_shipped, "famsum": rule_famsum, "fammax": rule_fammax}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log")
    parser.add_argument("--tau", type=float, default=0.30)
    parser.add_argument("--radius", type=float, default=12.0)
    parser.add_argument("--per-file", action="store_true",
                        help="also print per-file octave-clef outcomes")
    args = parser.parse_args()

    rows: list[tuple[str, str, list[tuple[str, float, float]]]] = []
    with open(args.log, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.search(line)
            if not m:
                continue
            cands = [
                (c.group("cls"), float(c.group("score")), float(c.group("dist")))
                for c in CAND.finditer(m.group("cands"))
                if float(c.group("dist")) <= args.radius
            ]
            rows.append((m.group("file"), m.group("vector"), cands))
    if not rows:
        print("no [mscz-clefcand] lines found", file=sys.stderr)
        return 1

    files = {r[0] for r in rows}
    print(f"clefs={len(rows)} files={len(files)} tau={args.tau} radius={args.radius}pt")

    # Per rule, per vector class: outcome counts.
    for name, rule in RULES.items():
        table: dict[str, Counter] = defaultdict(Counter)
        sibling_to: dict[str, Counter] = defaultdict(Counter)
        for _, vector, cands in rows:
            predicted = rule(cands, args.tau)
            o = outcome(vector, predicted)
            table[vector][o] += 1
            if o == "sibling":
                sibling_to[vector][predicted] += 1
        print(f"\n== rule {name} ==")
        print(f"{'vector':18s} {'n':>5s} {'exact':>6s} {'sibling':>8s} {'other':>6s} {'none':>5s}  sibling->")
        total = Counter()
        for vector in sorted(table, key=lambda v: -sum(table[v].values())):
            c = table[vector]
            n = sum(c.values())
            total.update(c)
            sib = " ".join(f"{k}:{v}" for k, v in sibling_to[vector].most_common())
            print(f"{vector:18s} {n:5d} {c['exact']:6d} {c['sibling']:8d} "
                  f"{c['other']:6d} {c['none']:5d}  {sib}")
        n = sum(total.values())
        print(f"{'ALL':18s} {n:5d} {total['exact']:6d} {total['sibling']:8d} "
              f"{total['other']:6d} {total['none']:5d}")

    # The split itself: for octave-clef truths, the best score of the exact
    # class vs the best score of its plain sibling, in the neighbourhood.
    print("\n== confidence split on octave-clef truths (best score in neighbourhood) ==")
    print(f"{'vector':18s} {'n':>5s} {'exact>tau':>9s} {'base>tau':>8s} {'both<tau':>8s} "
          f"{'mean exact':>10s} {'mean base':>9s}")
    for vector in sorted({r[1] for r in rows}):
        if family(vector) == vector:
            continue
        base = family(vector)
        n = 0
        exact_hi = base_hi = both_lo = 0
        exact_scores: list[float] = []
        base_scores: list[float] = []
        for _, v, cands in rows:
            if v != vector:
                continue
            n += 1
            e = max((c[1] for c in cands if c[0] == vector), default=0.0)
            b = max((c[1] for c in cands if c[0] == base), default=0.0)
            exact_scores.append(e)
            base_scores.append(b)
            if e > args.tau:
                exact_hi += 1
            if b > args.tau:
                base_hi += 1
            if e <= args.tau and b <= args.tau:
                both_lo += 1
        if n == 0:
            continue
        print(f"{vector:18s} {n:5d} {exact_hi:9d} {base_hi:8d} {both_lo:8d} "
              f"{sum(exact_scores) / n:10.3f} {sum(base_scores) / n:9.3f}")

    if args.per_file:
        print("\n== per file, octave-clef truths (shipped rule) ==")
        per_file: dict[str, Counter] = defaultdict(Counter)
        for file, vector, cands in rows:
            if family(vector) == vector:
                continue
            per_file[file][outcome(vector, rule_shipped(cands, args.tau))] += 1
        for file in sorted(per_file):
            c = per_file[file]
            print(f"{file}: " + " ".join(f"{k}={v}" for k, v in sorted(c.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
