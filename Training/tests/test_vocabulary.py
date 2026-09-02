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


def _parse_detector_table_names_from_source(text: str) -> list[str]:
    """Parse the class names out of a Swift source string that contains
    the `detectorTable` array literal.

    `detectorTable` is a static ordered array literal of
    `(String, SMuFLSemantic)` tuples; the class name is the first quoted
    string literal on each row, e.g. `("brace", .brace),`.

    Deliberately does NOT parse `detectorVocabulary` — that property is
    `.map`-computed from `detectorTable`, not a literal array, so there is
    no list of string literals to read there.

    Factored out from the path-based entry point below so unit tests can
    exercise the parser directly against synthetic Swift-like text,
    rather than depending on incidental properties (e.g. the absence of
    comments) of the real, append-only Swift source.

    Fails (never skips) when the marker-delimited segment can't be found
    or yields zero names: a silently-skipped drift detector is the exact
    failure mode this test exists to prevent.
    """
    start_marker = "static let detectorTable:"
    end_marker = "static let detectorVocabulary:"
    start = text.find(start_marker)
    end = text.find(end_marker)
    if start == -1 or end == -1 or end <= start:
        pytest.fail(
            "Could not locate the detectorTable array literal "
            f"(start={start}, end={end}). The Swift source layout may "
            "have changed; update the parser in this test."
        )
    segment = text[start:end]

    # Strip `//` line comments before matching, so a commented-out row
    # (e.g. left mid-refactor) is never picked up as a live class, and a
    # trailing comment that happens to contain a parenthesized quoted
    # word (e.g. "renamed from (...)") can't inject a spurious name.
    segment = re.sub(r"//[^\n]*", "", segment)

    # Each row looks like: ("brace", .brace),
    # The class name is the first quoted string literal on the row.
    # Assumes class names never contain an embedded (escaped) double
    # quote — they are plain camelCase identifiers in practice, so this
    # regex does not attempt to handle one.
    names = re.findall(r'\(\s*"([^"]+)"\s*,', segment)
    if not names:
        pytest.fail(
            "Parsed zero class names out of the detectorTable segment. "
            "The regex may no longer match the Swift source layout."
        )
    return names


def _parse_swift_detector_table_names() -> list[str]:
    """Path-based entry point: locate OMRLabelClassNames.swift relative to
    this test file, read it, and delegate to the string-based parser.

    Fails (never skips) when the Swift file can't be found: a silently-
    skipped drift detector is the exact failure mode this test exists to
    prevent.
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
    return _parse_detector_table_names_from_source(text)


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


def _parse_swift_unreachable_names(text: str) -> list[str]:
    """Class names whose `detectorTable` row carries an `// UNREACHABLE`
    marker. Read from the marker rather than from a second Swift list,
    because a second list is a thing that can drift from the first one
    silently -- the marker sits ON the row it describes."""
    start = text.find("static let detectorTable:")
    end = text.find("static let detectorVocabulary:")
    if start == -1 or end == -1 or end <= start:
        pytest.fail("Could not locate the detectorTable array literal.")
    return re.findall(r'\(\s*"([^"]+)"\s*,[^\n]*//\s*UNREACHABLE',
                      text[start:end])


def test_unreachable_classes_mirror_the_swift_markers():
    """`vocabulary.UNREACHABLE` and the Swift `// UNREACHABLE` row
    markers are the same claim written twice; drift between them means
    the gate exempts a class the label side still believes is drawable,
    or the reverse.

    Also pins the invariant that makes the exemption safe at all: an
    unreachable class is still IN the frozen list. The list is
    append-only because COCO category ids are positions in it, so the
    answer to "this class can never be drawn" is never to delete it.
    """
    swift = _parse_swift_unreachable_names(
        _swift_source_path().read_text(encoding="utf-8"))
    assert sorted(swift) == sorted(vocabulary.UNREACHABLE), {
        "swift": sorted(swift), "python": sorted(vocabulary.UNREACHABLE)}
    assert swift, "marker parse found nothing -- the Swift layout changed"
    for name, reason in vocabulary.UNREACHABLE.items():
        assert name in vocabulary.CLASS_NAMES
        assert reason.strip()


# --- Parser unit tests, against synthetic Swift-like text -----------------
#
# These exercise `_parse_detector_table_names_from_source` directly rather
# than the real Swift file: `detectorTable` is append-only and contains no
# comments today, so it can never exercise a comment-handling bug — pinning
# these cases to synthetic text means a future coincidence in the real
# source can't silently stop covering them.


def test_parser_ignores_commented_out_row():
    # If a class is ever removed from detectorTable by commenting the row
    # out instead of deleting it (mid-refactor, or left as a note), the
    # drift detector must still see the removal — not report false
    # agreement because the commented-out name was still matched.
    source = r"""
    enum OMRLabelClassNames {
        static let detectorTable: [(className: String, semantic: SMuFLSemantic)] = [
            ("brace", .brace),
            // ("staff5Lines", .staff5Lines),
            ("ornament", .ornament),
        ]

        static let detectorVocabulary: [String] = detectorTable.map(\.className)
    }
    """
    assert _parse_detector_table_names_from_source(source) == ["brace", "ornament"]


def test_parser_ignores_trailing_comment_with_parenthesized_quoted_word():
    # A trailing `//` comment that happens to contain a parenthesized
    # quoted word (e.g. documenting a rename) must not inject a spurious
    # extra class name.
    source = r"""
    enum OMRLabelClassNames {
        static let detectorTable: [(className: String, semantic: SMuFLSemantic)] = [
            ("brace", .brace), // renamed from ("oldBrace", .brace)
        ]

        static let detectorVocabulary: [String] = detectorTable.map(\.className)
    }
    """
    assert _parse_detector_table_names_from_source(source) == ["brace"]


def test_parser_handles_multiline_row():
    # Already works today — pinned so a future regex edit (e.g.
    # tightening it to match a single line) cannot silently stop matching
    # a row whose tuple is split across lines.
    source = r"""
    enum OMRLabelClassNames {
        static let detectorTable: [(className: String, semantic: SMuFLSemantic)] = [
            (
                "brace",
                .brace
            ),
        ]

        static let detectorVocabulary: [String] = detectorTable.map(\.className)
    }
    """
    assert _parse_detector_table_names_from_source(source) == ["brace"]
