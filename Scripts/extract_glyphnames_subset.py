import json, sys, re
src, out = sys.argv[1], sys.argv[2]
data = json.load(open(src))
def cp(s):  # "U+E0A4" -> 0xE0A4
    return int(s[2:], 16)
# Ranges we need wholesale, plus a guard list of explicit names.
def keep(name, code):
    return (0xE0A0 <= code <= 0xE0FF or   # noteheads
            0xE100 <= code <= 0xE10F or   # individual notes (named noteheads start ~E150)
            0xE150 <= code <= 0xE1CF or   # note name + shape note heads
            0xE260 <= code <= 0xE2FF or   # accidentals (standard + Stein/AEU/HE/ET/Persian/Wysch/Sagittal/Turkish)
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
json.dump(subset, open(out, "w"), indent=0, sort_keys=True)
print(f"{len(subset)} glyphs")
