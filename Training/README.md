# Training — synthetic OMR dataset generation (P3c)

Scripts that generate the synthetic training/eval datasets for the raster
OMR program (see docs/superpowers/specs/2026-08-06-omr-raster-foundation-design.md).
Datasets live OUTSIDE the repo at `~/Datasets/sheet-music-omr/<version>/`
(override with `OMR_DATA_ROOT`). Nothing dataset-sized or copyrighted is
ever committed; admissible sources are procedurally generated scores,
public-domain scores, and the repository owner's own originals only.

## Setup

    python3 -m venv Training/.venv
    Training/.venv/bin/pip install -r Training/requirements.txt

## Tests

    Training/.venv/bin/pytest Training/tests -q
