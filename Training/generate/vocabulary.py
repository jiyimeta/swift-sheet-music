"""Detector-class vocabulary — 1:1 mirror of the frozen Swift list in
Tests/SheetMusicTests/Helpers/OMRLabelClassNames.swift (`detectorTable`).
ORDER IS FROZEN and load-bearing: COCO category ids are positions here.
Append-only; any change must land in BOTH files in the same review.

Training/tests/test_vocabulary.py parses OMRLabelClassNames.swift directly
and asserts this list against it, so drift between the two fails a test
run instead of surfacing later as a label/dataset mismatch.
"""

CLASS_NAMES = [
    "brace",
    "noteheadDoubleWhole", "noteheadWhole", "noteheadHalf", "noteheadBlack",
    "noteheadXWhole", "noteheadXHalf", "noteheadXBlack",
    "flag8thUp", "flag8thDown", "flag16thUp", "flag16thDown",
    "flag32ndUp", "flag32ndDown", "flag64thUp", "flag64thDown",
    "augmentationDot",
    "restWhole", "restHalf", "restQuarter", "rest8th",
    "rest16th", "rest32nd", "rest64th",
    "clefG", "clefG8va", "clefG8vb", "clefG15ma", "clefG15mb",
    "clefF", "clefF8va", "clefF8vb", "clefF15ma", "clefF15mb",
    "clefC", "clefPercussion",
    "accidentalSharp", "accidentalFlat", "accidentalNatural",
    "accidentalDoubleSharp", "accidentalDoubleFlat",
    "timeSig0", "timeSig1", "timeSig2", "timeSig3", "timeSig4",
    "timeSig5", "timeSig6", "timeSig7", "timeSig8", "timeSig9",
    "timeSigCommon", "timeSigCutTime",
    "repeatBarlineDots",
    "segno", "coda", "dalSegno", "daCapo", "fine", "toCoda",
    "fermata",
    "dynamic", "articulation", "ornament",
]

RESERVED = ["stem", "staff5Lines", "rest128th", "rest256th", "restOther"]

#: Detector classes NOTHING can ever draw, with the reason. They are in
#: CLASS_NAMES and stay there: the list is frozen and append-only because
#: COCO category ids are positions in it, so a class cannot be removed
#: once shipped even after it turns out to be undrawable.
#:
#: Both are the same finding. SMuFL has no `fine` and no `toCoda` glyph —
#: MuseScore's own bundled `fonts/smufl/glyphnames.json` contains only
#: `coda` (U+E048) and `codaSquare` (U+E049) — and MuseScore engraves
#: both markers as WORDS. Words go to the PDF's text stream, and
#: `TextGlyph` carries no ink box by explicit design, so a text run
#: cannot yield a detector box at all. This repo does recover both
#: markers, from that text stream
#: (`PDFImporter+Structure.swift:239-241` maps the strings "Fine" and
#: "To Coda"), which is why the SCORE-level path has them and the
#: seam-level glyph path never can.
#:
#: Gate P3c-G3 subtracts these from its denominator and reports them on
#: their own `[coverage-unreachable]` line rather than counting them as
#: shortfalls. A gate that can never go green teaches its reader to stop
#: reading it; the exemption is recorded here, next to the frozen list
#: itself, so it cannot grow quietly.
UNREACHABLE = {
    "fine": "no SMuFL glyph; MuseScore draws the word (text stream)",
    "toCoda": "no SMuFL glyph; MuseScore draws the words (text stream)",
}
