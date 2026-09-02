"""Clef-context generator: octave clefs where real scores put them.

Round 2 of the detector (2026-09-02) starts from a measured defect: on a
real MuseScore render the heatmap splits its confidence between `clefF`
and `clefF8va` at the same cell and neither clears τ, while the synthetic
held-out set reports `clefF8va` recall 0.995. The census behind this
module says why the two disagree:

- every octave-clef glyph in the v2 dataset comes from `gen_coverage` --
  `cov_clef_<x>` (one staff, 8 bars) or `cov_clef_changes` (four
  cue-size mid-bar changes per bar);
- `gen_texture`'s realistic multi-part scores draw `G` / `F` / `PERC`
  only, plus `G8vb` on the "band" kind's Tenor part;
- and `clefG8vb` -- the one octave clef that DOES appear as a full-size
  system-start clef inside a multi-part score -- is the one the real
  corpus reads correctly.

So the model has never seen `F8va` (or `G8va`, `15ma`, `15mb`) as the
system-start clef of one staff among several in an ordinary score. This
module makes exactly that: `count` multi-part sources whose staves each
draw a default clef from the full pitched clef vocabulary, with the
melodic fabric reused from `gen_texture` so the surrounding ink is the
same kind of ink the model already trains on. Nothing else is new by
design -- the variable under test is the clef's context, and only that.

Sources are named `clx_0000` … so their ids sort after `cov_*` and
before `tex_*`, and hash into `prep.split_of`'s buckets like any other
source. `count = 0` (the default everywhere) leaves an existing dataset
byte-identical -- P3c-G1 on v2 is unaffected.
"""
from __future__ import annotations

import numpy as np

from generate.gen_texture import _walk_measure
from generate.mscx_builder import PartSpec, StaffSpec, mscx_document

#: `<defaultClef>` tokens a pitched staff can carry, with a diatonic
#: (C-major) MIDI pitch that sits mid-staff under each, so the random
#: walk `gen_texture._walk_measure` runs stays on or near the staff and
#: the clef is the clef the notes are written for. `PERC` is excluded:
#: percussion staves are a different staff group and `gen_texture`
#: already draws them.
CLEF_BASES: dict[str, int] = {
    "G": 72, "G8va": 84, "G8vb": 60, "G15ma": 96, "G15mb": 48,
    "F": 50, "F8va": 62, "F8vb": 38, "F15ma": 74, "F15mb": 26,
    "C3": 60,
}

#: Part names are decoration (the detector reads no text), but a real
#: score has them and their ink sits left of the system-start clef, which
#: is the neighbourhood this module is about.
_PART_NAMES = ["Flute", "Oboe", "Clarinet", "Horn", "Trumpet", "Trombone",
               "Violin", "Viola", "Cello", "Bass", "Soprano", "Alto",
               "Tenor", "Piano", "Guitar", "Harp"]

_PARTS_MIN, _PARTS_MAX = 2, 8


#: Half of all staves are plain `G` / `F`, the other half draw uniformly
#: from the nine remaining tokens. The real failure is an octave clef
#: sitting AMONG plain ones (a bass-8va staff in a score whose other
#: staves are ordinary), so the plain clefs stay the majority neighbour
#: rather than one token in eleven; each octave variant still lands on
#: about one staff in eighteen, which sizes a root of ~80 sources at
#: roughly 2k system-start glyphs per variant.
_PLAIN_SHARE = 0.5
_PLAIN = ["G", "F"]
_OTHERS = sorted(c for c in CLEF_BASES if c not in _PLAIN)


def _draw_clef(rng) -> str:
    if rng.random() < _PLAIN_SHARE:
        return str(rng.choice(_PLAIN))
    return str(rng.choice(_OTHERS))


def _staff_measures(rng, clef: str, n_measures: int) -> list[str]:
    base = CLEF_BASES[clef]
    return [_walk_measure(rng, base, False, m == 0) for m in range(n_measures)]


def clefctx_sources(seed: int, count: int) -> list[tuple[str, str]]:
    """`count` independently-reproducible multi-part `.mscx` sources
    named `clx_0000` … `clx_{count-1:04d}`, each part's staff under a
    default clef drawn uniformly from `CLEF_BASES`. Roughly one part in
    six is a braced grand staff whose two staves draw their clefs
    independently. Deterministic per (seed, index), like
    `gen_texture.texture_sources`."""
    root_rng = np.random.default_rng(seed)
    child_seeds = root_rng.integers(0, 2**32, size=count)
    sources: list[tuple[str, str]] = []
    for i in range(count):
        rng = np.random.default_rng(int(child_seeds[i]))
        n_measures = int(rng.integers(8, 17))
        n_parts = int(rng.integers(_PARTS_MIN, _PARTS_MAX + 1))
        names = list(rng.permutation(_PART_NAMES)[:n_parts])
        parts: list[PartSpec] = []
        for name in names:
            clef = _draw_clef(rng)
            part = PartSpec(name=str(name), clef=clef,
                            measures=_staff_measures(rng, clef, n_measures))
            if rng.random() < 1 / 6:
                lower = _draw_clef(rng)
                part.extra_staves = [StaffSpec(
                    clef=lower, measures=_staff_measures(rng, lower, n_measures))]
                part.braced = True
            parts.append(part)
        sources.append((f"clx_{i:04d}", mscx_document(parts)))
    return sources
