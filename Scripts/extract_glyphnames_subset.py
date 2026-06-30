import json, sys, re
src, out = sys.argv[1], sys.argv[2]
data = json.load(open(src))
def cp(s):  # "U+E0A4" -> 0xE0A4
    return int(s[2:], 16)
# Ranges we need wholesale, plus a guard list of explicit names.
# fmt: off
EXTRA_NAMES = frozenset({
    # Sagittal accidentals (E310–E319) — sparse subset used by MuseScore
    "accSagittalSharp25SDown", "accSagittalFlat25SUp",
    "accSagittalSharp7CDown",  "accSagittalFlat7CUp",
    "accSagittalSharp5CDown",  "accSagittalFlat5CUp",
    "accSagittalSharp5v7kDown","accSagittalFlat5v7kUp",
    "accSagittalSharp",        "accSagittalFlat",
    # Wyschnegradsky accidentals (E420–E435, complete block)
    "accidentalWyschnegradsky1TwelfthsSharp",
    "accidentalWyschnegradsky2TwelfthsSharp",
    "accidentalWyschnegradsky3TwelfthsSharp",
    "accidentalWyschnegradsky4TwelfthsSharp",
    "accidentalWyschnegradsky5TwelfthsSharp",
    "accidentalWyschnegradsky6TwelfthsSharp",
    "accidentalWyschnegradsky7TwelfthsSharp",
    "accidentalWyschnegradsky8TwelfthsSharp",
    "accidentalWyschnegradsky9TwelfthsSharp",
    "accidentalWyschnegradsky10TwelfthsSharp",
    "accidentalWyschnegradsky11TwelfthsSharp",
    "accidentalWyschnegradsky1TwelfthsFlat",
    "accidentalWyschnegradsky2TwelfthsFlat",
    "accidentalWyschnegradsky3TwelfthsFlat",
    "accidentalWyschnegradsky4TwelfthsFlat",
    "accidentalWyschnegradsky5TwelfthsFlat",
    "accidentalWyschnegradsky6TwelfthsFlat",
    "accidentalWyschnegradsky7TwelfthsFlat",
    "accidentalWyschnegradsky8TwelfthsFlat",
    "accidentalWyschnegradsky9TwelfthsFlat",
    "accidentalWyschnegradsky10TwelfthsFlat",
    "accidentalWyschnegradsky11TwelfthsFlat",
    # Turkish / AEU (E440–E447, sparse subset)
    "accidentalBuyukMucennebFlat",
    "accidentalBakiyeFlat",
    "accidentalKucukMucennebSharp",
    "accidentalBuyukMucennebSharp",
    # Persian comma accidentals (E450–E457, complete block)
    "accidental1CommaSharp", "accidental2CommaSharp",
    "accidental3CommaSharp", "accidental5CommaSharp",
    "accidental1CommaFlat",  "accidental2CommaFlat",
    "accidental3CommaFlat",  "accidental4CommaFlat",
    # Persian Koron / Sori (E460–E461)
    "accidentalKoron", "accidentalSori",
})
# fmt: on
def keep(name, code):
    return (name in EXTRA_NAMES or
            0xE0A0 <= code <= 0xE0FF or   # noteheads
            0xE100 <= code <= 0xE10F or   # individual notes (named noteheads start ~E150)
            0xE150 <= code <= 0xE1CF or   # note name + shape note heads
            0xE260 <= code <= 0xE2FF or   # accidentals (standard + Stein/HE/ET)
            0xE300 <= code <= 0xE30F or   # some extended accidentals
            0xEAA0 <= code <= 0xEABF or   # wiggle / vibrato / glissando lines
            0xECD0 <= code <= 0xECDD or   # shape-note DoubleWhole variants
            0xEE70 <= code <= 0xEE73 or   # Swiss rudiment noteheads
            0xEEE0 <= code <= 0xEEFA)     # chromatic / named-note solfège
subset = {}
for name, v in data.items():
    code = cp(v["codepoint"])
    if keep(name, code):
        subset[name] = code
with open(out, "w") as f:
    json.dump(subset, f, indent=0, sort_keys=True)
    f.write("\n")
print(f"{len(subset)} glyphs")
