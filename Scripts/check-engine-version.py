#!/usr/bin/env python3
"""Fails when `SheetMusicEngine.version` is not the newest released version in CHANGELOG.md, or not the tag.

    Scripts/check-engine-version.py [--expect X.Y.Z]

`SheetMusicEngine.version` is what a host's engine-skew gate compares: Android hashes it on both sides of the JNI
boundary (`versionStamp`) and refuses to open an edit session when the library's `.so` and the host's own image
disagree. It is a hand-written literal, so it only means something if every release moves it. From 4.14.2 to 4.45.0
no release commit did — each added its CHANGELOG heading alone — and the constant read "4.14.1" through all of them,
so any two builds in that range stamped alike and the gate let every skew through.

Lint runs this on every push, so a release heading added without the bump fails on the branch, before a tag exists.
The Android publish workflow runs it with `--expect <tag>`, so a tag that disagrees with the constant publishes
nothing. A work-in-progress suffix (`4.46.0-w1`, the constant's own doc asks for one on a topic build that is
published locally) is reported and passes: it can never be tagged, because `--expect` compares the whole string.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT / "Sources" / "SheetMusicCore" / "SheetMusicEngine.swift"
CHANGELOG = ROOT / "CHANGELOG.md"
VERSION_PATTERN = re.compile(r'public static let version = "([^"]+)"')
HEADING_PATTERN = re.compile(r"^## \[(\d+\.\d+\.\d+)\]", re.M)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--expect", help="the version being published (a tag without its leading v)")
    arguments = parser.parse_args()

    engine = VERSION_PATTERN.search(ENGINE.read_text(encoding="utf-8"))
    if engine is None:
        print(f"check-engine-version: no `public static let version = \"…\"` in {ENGINE.relative_to(ROOT)}")
        return 1
    version = engine.group(1)
    heading = HEADING_PATTERN.search(CHANGELOG.read_text(encoding="utf-8"))
    if heading is None:
        print("check-engine-version: CHANGELOG.md has no released `## [X.Y.Z]` heading")
        return 1
    released = heading.group(1)

    if arguments.expect is not None and version != arguments.expect:
        print(f"check-engine-version: publishing {arguments.expect}, but SheetMusicEngine.version is {version}")
        return 1
    if version == released:
        print(f"check-engine-version: SheetMusicEngine.version {version} is CHANGELOG's newest release")
        return 0
    if re.fullmatch(r"\d+\.\d+\.\d+-[A-Za-z0-9.-]+", version):
        print(f"check-engine-version: SheetMusicEngine.version {version} is a work-in-progress stamp "
              f"(CHANGELOG's newest release is {released}); it cannot be published under a release tag")
        return 0
    print(f"check-engine-version: SheetMusicEngine.version is {version}, but CHANGELOG's newest release is "
          f"{released}. Move the constant (and SheetMusicEngineTests' two expectations) in the commit that adds "
          f"the heading.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
