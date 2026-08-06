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
