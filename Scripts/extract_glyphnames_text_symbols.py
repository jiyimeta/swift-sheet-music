"""Extract the SMuFL names MuseScore writes inside text or as a symbol subtype.

They feed only `SMuFLCodepoint.byName(_:)`: GenSMuFLTables merges them into the by-name table without emitting
constants, because several of them (segno, coda, fermataAbove, the artic* family) already exist as hand-written
constants in SMuFLCodepoints.swift and a second declaration would not compile.

Usage: extract_glyphnames_text_symbols.py <glyphnames.json> <out.json>
"""
import json
import sys

PREFIXES = (
    "dynamic",             # <sym>dynamicPiano</sym> in dynamics and expression text
    "metNote",             # tempo text: metNoteQuarterUp
    "metAugmentationDot",
    "segno",               # segno family (markers)
    "coda",                # coda family (markers, "To <sym>coda</sym>")
    "fermata",             # fermata family (<Symbol>, fermata subtypes)
    "caesura",             # caesura family (breath subtypes)
    "breathMark",
    "chantCaesura",
    "keyboardPedal",       # keyboard pedal texts
    "harpPedal",           # harp pedal diagrams
    "fretboard",           # fretboard diagrams
    "figbass",             # figured bass
    "artic",               # articulation names a <Symbol> carries
    "text",                # tempo / swing text: textBlackNote*, textCont*Beam*, textTuplet*, textAugmentationDot, textTie
    "lyrics",              # lyric elisions: the editor inserts <sym>lyricsElision</sym> (editing/textedit.cpp:738)
    "ornament",            # <Symbol> ornaments (ornamentTrill, ornamentTurn, ...)
    "csymAccidental",      # harp pedal text diagrams: B<sym>csymAccidentalNatural</sym>
    "guitarString",        # string-tunings text: guitarString1 ... guitarString13
    "strings",             # bow marks and harmonics a <Symbol> names (stringsUpBow, ...)
    "fingering",           # the fingering glyph palette (fingering1, fingeringPLower, ...)
    "tremolo",             # tremolo glyphs a <Symbol> names (tremoloFingered1, ...)
)


def main() -> None:
    src, out = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as handle:
        data = json.load(handle)
    subset = {
        name: int(value["codepoint"][2:], 16)
        for name, value in data.items()
        if name.startswith(PREFIXES)
    }
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(subset, handle, indent=0, sort_keys=True)
        handle.write("\n")
    print(f"{len(subset)} glyphs")


if __name__ == "__main__":
    main()
