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

## MuseScore CLI export (`generate/export_pdf.py`)

Renders a generated `.mscx`/`.mscz` source to PDF via the MuseScore CLI,
under process supervision that encodes measured (not assumed) MuseScore
behavior: MuseScore 4's PDF export can write a complete file and then
never exit, and its crash reporter can make a successful export exit
non-zero. Success is judged only by output-file completeness (trailing
`%%EOF` + a readable page count); exit codes and timeouts are recorded
but never trusted. One retry; a still-incomplete output after the retry
is the caller's cue to quarantine the source.

Engine binary locations are environment-overridable rather than
hard-coded, since MuseScore.app's install path is host-specific:

    OMR_MSCORE4_BIN   default: /Applications/MuseScore 4.app/Contents/MacOS/mscore
    OMR_MSCORE3_BIN   default: /Applications/MuseScore 3.app/Contents/MacOS/mscore

Note MuseScore 3 refuses to open a score written by a newer MuseScore,
so an MS3-schema source is required for the MS3 arm to do anything at
all; and MS3's macOS build has no `offscreen` QPA platform (`cocoa` is
the only one available), unlike MS4.
