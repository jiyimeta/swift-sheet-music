#!/usr/bin/env python3
"""Fails when a public declaration of a Windows module names a type from SheetMusicBridgeCore.

SheetMusicBridgeCore is not a product: it is the JNI and wasm bridges' plumbing, and its draw-program types grow by
appending cases (`DrawCommand`), which would break every Swift host that switches over them. The Windows modules are
products, so their public surface must speak in product types only (`ScorePages`, `ScorePageOptions`, `PageRectMM`
in SheetMusicRenderWindows; SheetMusicCore / SheetMusicLayout / SheetMusicAudioCore types elsewhere).

A declaration is read from its `public` / `open` line up to the `{` or the end of the statement, so a signature split
over several lines is checked whole. Doc comments and string literals are ignored.

    Scripts/check-windows-public-api.py
"""
import pathlib
import re
import sys

MODULES = ["Sources/SheetMusicRenderWindows", "Sources/SheetMusicAudioWindows"]
BRIDGE_TYPES = [
    "EncodablePage", "DrawCommand", "DrawProgram", "SystemSpan", "DrawRect", "LayoutOptionsWire", "LayoutPages",
    "FontMetricsTable", "LayoutBridge",
]
pattern = re.compile(r"\b(" + "|".join(BRIDGE_TYPES) + r")\b")
start = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*(public|open)\b")


enum_start = re.compile(r"^\s*(?:(public|open|package|internal|private|fileprivate)\s+)?(?:indirect\s+)?enum\s+\w+")
case_line = re.compile(r"^\s*case\s+\w+\s*\(")


def declarations(lines):
    """Yields (line number, text) for each public / open declaration, continuation lines included, and for each
    `case` with associated values in the nearest enclosing-looking enum when that enum is public (its cases carry no
    modifier of their own). Nested enums are rare here; the nearest enum declaration above is taken as the owner."""
    index = 0
    public_enum = False
    while index < len(lines):
        line = lines[index]
        declared = enum_start.match(line)
        if declared:
            public_enum = declared.group(1) in ("public", "open")
        if public_enum and case_line.match(line):
            yield index + 1, line
        if start.match(line) and not line.lstrip().startswith("//"):
            first = index
            text = line
            while "{" not in text and not text.rstrip().endswith(("}", ")")) and index + 1 < len(lines):
                nxt = lines[index + 1]
                if start.match(nxt) or nxt.strip() == "":
                    break
                index += 1
                text += " " + nxt.strip()
            yield first + 1, text.split("{")[0]
        index += 1


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    found = []
    checked = 0
    for module in MODULES:
        for path in sorted((root / module).rglob("*.swift")):
            lines = path.read_text().splitlines()
            for number, text in declarations(lines):
                checked += 1
                code = re.sub(r'"[^"]*"', '""', text)
                for match in pattern.finditer(code):
                    found.append(f"{path.relative_to(root)}:{number}: public API names {match.group(1)}")
    for line in found:
        print(line)
    print(f"checked {checked} public declarations in {', '.join(MODULES)}")
    if checked == 0:
        print("error: found no public declaration at all — the module paths above no longer exist?")
        return 2
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
