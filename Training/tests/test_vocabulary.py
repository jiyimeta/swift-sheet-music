import re
from pathlib import Path

import pytest

from generate import vocabulary


def _swift_source_path() -> Path:
    # Training/tests/test_vocabulary.py -> parents[0]=tests, [1]=Training,
    # [2]=repo root. Locate relative to this file, not cwd or a hard-coded
    # absolute path, so the test works from any checkout/worktree.
    repo_root = Path(__file__).resolve().parents[2]
    return repo_root / "Tests" / "SheetMusicTests" / "Helpers" / "OMRLabelClassNames.swift"


def _parse_swift_detector_table_names() -> list[str]:
    """Parse the class names out of OMRLabelClassNames.detectorTable.

    `detectorTable` is a static ordered array literal of
    `(String, SMuFLSemantic)` tuples; the class name is the first quoted
    string literal on each row, e.g. `("brace", .brace),`.

    Deliberately does NOT parse `detectorVocabulary` — that property is
    `.map`-computed from `detectorTable`, not a literal array, so there is
    no list of string literals to read there.

    Fails (never skips) when the Swift source can't be found or parsed:
    a silently-skipped drift detector is the exact failure mode this test
    exists to prevent.
    """
    path = _swift_source_path()
    if not path.is_file():
        pytest.fail(
            f"Cannot locate the Swift vocabulary source at {path}. "
            "The drift detector must fail loudly, not skip, when it "
            "cannot verify Training/generate/vocabulary.py against "
            "OMRLabelClassNames.swift."
        )
    text = path.read_text(encoding="utf-8")

    start_marker = "static let detectorTable:"
    end_marker = "static let detectorVocabulary:"
    start = text.find(start_marker)
    end = text.find(end_marker)
    if start == -1 or end == -1 or end <= start:
        pytest.fail(
            f"Could not locate the detectorTable array literal in {path} "
            f"(start={start}, end={end}). The Swift source layout may "
            "have changed; update the parser in this test."
        )
    segment = text[start:end]

    # Each row looks like: ("brace", .brace),
    # The class name is the first quoted string literal on the row.
    names = re.findall(r'\(\s*"([^"]+)"\s*,', segment)
    if not names:
        pytest.fail(
            f"Parsed zero class names out of the detectorTable segment in "
            f"{path}. The regex may no longer match the Swift source "
            "layout."
        )
    return names


def test_vocabulary_has_64_unique_classes():
    assert len(vocabulary.CLASS_NAMES) == 64
    assert len(set(vocabulary.CLASS_NAMES)) == 64


def test_spec_examples_present_and_reserved_excluded():
    for name in ["noteheadBlack", "rest8th", "timeSig4", "clefG8vb", "timeSigCutTime"]:
        assert name in vocabulary.CLASS_NAMES
    for name in vocabulary.RESERVED:
        assert name not in vocabulary.CLASS_NAMES


def test_order_is_frozen_at_the_ends():
    # Order is load-bearing (COCO category ids). Pin both ends.
    assert vocabulary.CLASS_NAMES[0] == "brace"
    assert vocabulary.CLASS_NAMES[-1] == "ornament"


def test_matches_swift_detector_table():
    """Drift detector: Training/generate/vocabulary.py must mirror
    OMRLabelClassNames.detectorTable in
    Tests/SheetMusicTests/Helpers/OMRLabelClassNames.swift exactly — same
    names, same order. This test parses the Swift source directly rather
    than relying on a human to eyeball the two lists, so a class added to
    one side and not the other fails loudly here instead of surfacing
    later as a label/dataset mismatch.
    """
    swift_names = _parse_swift_detector_table_names()
    python_names = list(vocabulary.CLASS_NAMES)

    if swift_names == python_names:
        return

    only_in_swift = [name for name in swift_names if name not in python_names]
    only_in_python = [name for name in python_names if name not in swift_names]

    messages = []
    if only_in_swift:
        messages.append(
            "present in Swift detectorTable but missing from "
            f"vocabulary.CLASS_NAMES: {only_in_swift}"
        )
    if only_in_python:
        messages.append(
            "present in vocabulary.CLASS_NAMES but missing from Swift "
            f"detectorTable: {only_in_python}"
        )
    if not messages and len(swift_names) == len(python_names):
        # Same set of names, different order — report the first mismatch.
        for index, (swift_name, python_name) in enumerate(zip(swift_names, python_names)):
            if swift_name != python_name:
                messages.append(
                    f"order mismatch at index {index}: Swift has "
                    f"{swift_name!r}, Python has {python_name!r}"
                )
                break
    if not messages:
        messages.append(
            f"lists differ (Swift has {len(swift_names)} entries, Python "
            f"has {len(python_names)} entries) but no per-name diff was "
            "found — inspect both lists directly"
        )

    pytest.fail(
        "Training/generate/vocabulary.py has drifted from "
        "OMRLabelClassNames.detectorTable:\n  " + "\n  ".join(messages)
    )
