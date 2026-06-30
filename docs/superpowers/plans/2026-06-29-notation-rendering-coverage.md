# Notation Rendering Coverage Expansion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render every MuseScore notehead group (type + small/cue size), every accidental type (incl. parenthesis/bracket enclosure), vibrato lines, and wavy glissandi at the correct SMuFL glyphs — and emit decode-time diagnostics for genuinely-unsupported subtypes so the Folino Crashlytics pipeline reports them.

**Architecture:** Glyph-based elements (noteheads, accidentals) resolve their SMuFL codepoint through shared `SheetMusicLayout` tables (`NoteheadGlyph` / `AccidentalGlyph`) that the CALayer renderer, the legacy Canvas renderer, and the Android `LayoutBridge` all consume — so extending the tables benefits all render paths. The ~75 notehead groups × 4 types and ~80 accidental types are too large to hand-transcribe codepoints for, so a dev-only generator (`GenSMuFLTables`) joins the studied MuseScore group→SymId / type→SymId mappings with SMuFL `glyphnames.json` and emits committed Swift codepoint tables. Vibrato and wavy glissando render as repeated SMuFL wiggle glyphs (so they cross the Android wire as glyph ops). Small/cue noteheads reuse the grace-note `mag` precedent.

**Tech Stack:** Swift 6, SwiftPM. SwiftUI/CALayer (Apple rendering). Swift Testing (`@Test`/`#expect`). MuseScore C++ as behavioural reference only (`~/Developer/musescore/MuseScore`, GPL — studied, never copied). SMuFL/Bravura glyphs.

## Global Constraints

- **Idiomatic Swift naming**; original C++ class/enum names go in `/// C++: …` doc comments only.
- **Value types** (`struct`/`enum`), `Sendable`, no back-pointers.
- **One responsibility per file; SwiftLint caps files at 300 lines** — split generated tables across `+Noteheads` / `+Accidentals` / `+Lines` files.
- **Errors via `throws`**, single `SheetMusicError`. Non-fatal anomalies use `ScoreDiagnostic` via `mscxDecoderWarn` (embellishment-class policy: drop to safe default **and** warn).
- **Tests use Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest. Test target `@testable import`s each sub-library individually (re-exports don't grant testable access).
- **No GPL into `Sources/`.** MuseScore mappings are re-expressed as our own tables with `/// C++: <file>:<line>` provenance comments; SMuFL codepoint integers are facts from `glyphnames.json`.
- **Android gate:** any new test importing an Apple framework or `@testable`-importing an Apple-only sub-library (`SheetMusicLayout`, `SheetMusicUI`) must be wrapped in `#if !os(Android)`. Run `Scripts/gate-android-tests.sh` after adding tests.
- **Public-enum changes ripple into the example app** (outside the SwiftPM build graph): after changing `Accidental` / `Spanner.Kind` / `LayoutElement.SpannerKind`, verify Mac **and** iOS `xcodebuild` (regenerate `Examples/Apple` with `xcodegen` first).
- **Adding a public-enum case requires updating every exhaustive switch over it in the same task** (build breaks otherwise).
- **MuseScore reference paths** in this plan are relative to `~/Developer/musescore/MuseScore`.
- Default language for docs/comments/commits is **English**.

---

## File Structure

**New (Core — `Sources/SheetMusicCore`):**
- `Score/AccidentalType.swift` — the full `Accidental` enum (renamed conceptually; see Task 3.1) + `AccidentalBracket`.
- `Score/AccidentalOffsets.swift` — `Accidental` → semitone pitch offset table (drives `PitchSpelling`).
- `Score/VibratoType.swift` — `VibratoType` enum + `Spanner.VibratoPayload`.

**New (Layout — `Sources/SheetMusicLayout/Engraving`):**
- `NoteHeadGroup.swift` — `NoteHeadGroup` enum, MS4-token↔group, `noteHeads[group][type]` SymId-name table (stem-dir branch).
- `SMuFLGlyphName.swift` — `SymId`-name → codepoint resolution (generated constants live in the `+*` files below).
- `SMuFLCodepoints+Noteheads.swift` *(generated)* — notehead codepoint constants.
- `SMuFLCodepoints+Accidentals.swift` *(generated)* — accidental codepoint constants.
- `SMuFLCodepoints+Lines.swift` *(generated)* — vibrato/glissando wiggle codepoint constants.

**New (dev tooling):**
- `Sources/GenSMuFLTables/main.swift` — dev-only executable; reads `glyphnames.json`, emits the three generated files. Added as an `.executableTarget` guarded so it isn't a library product.

**Modified:**
- Core: `Score/Note.swift` (add `accidentalBracket`, `isSmall`), `Score/Spanner.swift` (add `.vibrato` Kind + `vibrato` payload), `PitchSpelling.swift`.
- Layout: `Engraving/NoteheadGlyph.swift` (rewrite), `Engraving/AccidentalGlyph.swift` (rewrite), `Layout/LayoutElement.swift` (`SpannerKind.vibrato`, chord `mag`, spanner vibrato payload), `Layout/LayoutEngine+Spanners.swift` (`layoutKind`, `isBelowStaff`), `Layout/LayoutEngine+Placement.swift` (small mag).
- MSCX: `Decoders/MSCXDecoder+Note.swift` (headType normalization, small, accidental subtype + bracket, diagnostics), `Decoders/MSCXDecoder+Spanner.swift` (vibrato), `Encoders/MSCXEncoder+Note.swift` (accidental full set + bracket + small).
- UI (CALayer): `Rendering/ScoreLayerBuilder+Chord.swift` (small mag, accidental enclosure, measured accidental offset), `Rendering/ScoreLayerBuilder+Spanners.swift` (vibrato), `Rendering/ScoreLayerBuilder+Glissando.swift` (wavy glyph).
- UI (Canvas, parity): `Rendering/NoteheadRenderer.swift`, `AccidentalRenderer.swift`, `SpannerRenderer.swift`, `GlissandoRenderer.swift`.
- Android: `Sources/SheetMusicAndroidJNI/LayoutBridge+Engraving.swift` (vibrato spanner case), `LayoutBridge+Chord.swift` (small mag, accidental enclosure/offset), `LayoutBridge+Glissando.swift` (wavy glyph).
- `Package.swift` (add `GenSMuFLTables` executable target).

**Data appendix:** the full notehead group→SymId-name table, accidental type→SymId-name + offset table, and token strings are in **Appendix A** at the end of this plan. The generator transcribes from there.

---

## Phase 0 — SMuFL codepoint foundation (generated tables)

### Task 0.1: Vendor the SMuFL glyphnames subset

**Files:**
- Create: `Sources/SheetMusicLayout/Resources/glyphnames-subset.json`
- Create: `Scripts/extract-glyphnames-subset.sh`

**Interfaces:**
- Produces: a JSON object `{ "<symIdName>": <codepointInt>, … }` covering the notehead (`U+E0A0–E0FF`), shape-note, named-notehead, accidental (`U+E260–E2FF`), and wiggle (`U+EAA0–EABF`) ranges plus every SymId name referenced in Appendix A.

- [ ] **Step 1: Write the extraction script**

`Scripts/extract-glyphnames-subset.sh` (reads the canonical SMuFL file, emits the subset as `name → codepointInt`):

```bash
#!/usr/bin/env bash
# Extract the SMuFL glyphnames subset this package needs from a full
# glyphnames.json (SMuFL data; codepoints are facts). Source defaults to
# the MuseScore clone. Usage: extract-glyphnames-subset.sh [path-to-glyphnames.json]
set -euo pipefail
SRC="${1:-$HOME/Developer/musescore/MuseScore/fonts/smufl/glyphnames.json}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Sources/SheetMusicLayout/Resources/glyphnames-subset.json"
mkdir -p "$(dirname "$OUT")"
# glyphnames.json entries look like: "noteheadBlack": { "codepoint": "U+E0A4", ... }
# Emit a flat { name: <int> } map for names in the ranges + explicit list we use.
python3 "$(dirname "$0")/extract_glyphnames_subset.py" "$SRC" "$OUT"
echo "wrote $OUT"
```

`Scripts/extract_glyphnames_subset.py`:

```python
import json, sys, re
src, out = sys.argv[1], sys.argv[2]
data = json.load(open(src))
def cp(s):  # "U+E0A4" -> 0xE0A4
    return int(s[2:], 16)
# Ranges we need wholesale, plus a guard list of explicit names.
def keep(name, code):
    return (0xE0A0 <= code <= 0xE0FF or   # noteheads
            0xE100 <= code <= 0xE10F or   # individual notes (named noteheads start ~E150)
            0xE150 <= code <= 0xE1AF or   # note name + shape note heads
            0xE260 <= code <= 0xE2FF or   # accidentals (standard + Stein/AEU/HE/ET/Persian/Wysch/Sagittal/Turkish)
            0xE300 <= code <= 0xE30F or   # some extended accidentals
            0xEAA0 <= code <= 0xEABF)     # wiggle / vibrato / glissando lines
subset = {}
for name, v in data.items():
    code = cp(v["codepoint"])
    if keep(name, code):
        subset[name] = code
json.dump(subset, open(out, "w"), indent=0, sort_keys=True)
print(f"{len(subset)} glyphs")
```

- [ ] **Step 2: Run the extraction**

Run: `chmod +x Scripts/extract-glyphnames-subset.sh && Scripts/extract-glyphnames-subset.sh`
Expected: prints `… glyphs` and `wrote …/glyphnames-subset.json`. Open the file and confirm it contains e.g. `"noteheadCircleX"`, `"accidentalParensLeft"`, `"wiggleGlissando"`, `"guitarVibratoStroke"`.

> If `~/Developer/musescore/MuseScore/fonts/smufl/glyphnames.json` is absent, clone MuseScore or pass a path to any SMuFL `glyphnames.json`. The subset is committed, so this runs once.

- [ ] **Step 3: Commit**

```bash
git add Scripts/extract-glyphnames-subset.sh Scripts/extract_glyphnames_subset.py Sources/SheetMusicLayout/Resources/glyphnames-subset.json
git commit -m "build: vendor SMuFL glyphnames subset for notation coverage"
```

### Task 0.2: Generator executable that emits codepoint tables

**Files:**
- Create: `Sources/GenSMuFLTables/main.swift`
- Modify: `Package.swift` (add the executable target)
- Create (generated by running it): `Sources/SheetMusicLayout/Engraving/SMuFLCodepoints+Noteheads.swift`, `+Accidentals.swift`, `+Lines.swift`

**Interfaces:**
- Produces: extends `enum SMuFLCodepoint` with `static let <symIdName>: UInt32 = 0x…` for every SymId name in Appendix A; one file per category, each < 300 lines.

- [ ] **Step 1: Add the executable target to `Package.swift`**

In `Package.swift` `targets:`, add (it depends on nothing; reads/writes files):

```swift
.executableTarget(
    name: "GenSMuFLTables",
    path: "Sources/GenSMuFLTables"
),
```

Do **not** add it to `products:` — it is dev-only. Re-run `swift package describe` with and without `SWIFT_SHEET_MUSIC_ANDROID=1` to confirm both manifest shapes still resolve.

- [ ] **Step 2: Write the generator**

`Sources/GenSMuFLTables/main.swift` — reads the committed subset JSON, takes the SymId-name lists for each category (transcribed from Appendix A), and emits the three Swift files. Each emitted file groups `static let name: UInt32 = 0x…` lines under a `// MARK:` and stays under 300 lines (split a category across multiple `extension SMuFLCodepoint` blocks if needed):

```swift
import Foundation

// Dev-only. Run: swift run GenSMuFLTables
// Emits SMuFLCodepoint constants for every SymId name the notehead /
// accidental / line tables reference, resolved from the committed
// glyphnames subset (SMuFL data). Re-run after editing the name lists.

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let subsetURL = repoRoot.appendingPathComponent(
    "Sources/SheetMusicLayout/Resources/glyphnames-subset.json")
let engravingDir = repoRoot.appendingPathComponent("Sources/SheetMusicLayout/Engraving")

let subset = try JSONDecoder().decode(
    [String: UInt32].self, from: Data(contentsOf: subsetURL))

// SymId-name lists — the deduplicated names from Appendix A.1 (noteheads)
// and Appendix A.5 (accidentals); see Appendix A.2 / A.6 for how to derive.
let noteheadNames: [String] = [ /* dedup of every SymId in Appendix A.1, minus "noSym" */ ]
let accidentalNames: [String] = [ /* dedup of every subtype SymId in Appendix A.5 */ ]
let lineNames: [String] = [
    "wiggleGlissando", "guitarVibratoStroke", "guitarWideVibratoStroke",
    "wiggleSawtooth", "wiggleSawtoothWide",
    "accidentalParensLeft", "accidentalParensRight",
    "accidentalBracketLeft", "accidentalBracketRight",
]

func emit(_ names: [String], header: String, file: String) throws {
    var missing: [String] = []
    var lines = ["import Foundation", "",
                 "// Generated by GenSMuFLTables — do not edit by hand.",
                 "// Codepoints are SMuFL facts from glyphnames.json.",
                 "// \(header)", "extension SMuFLCodepoint {"]
    for name in names.sorted() {
        guard let cp = subset[name] else { missing.append(name); continue }
        lines.append(String(format: "    public static let %@: UInt32 = 0x%04X", name, cp))
    }
    lines.append("}")
    if !missing.isEmpty {
        FileHandle.standardError.write(Data("MISSING in subset: \(missing)\n".utf8))
        exit(1)
    }
    try lines.joined(separator: "\n").appending("\n")
        .write(to: engravingDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    print("wrote \(file): \(names.count) glyphs")
}

try emit(noteheadNames, header: "MARK: - Noteheads (full set)", file: "SMuFLCodepoints+Noteheads.swift")
try emit(accidentalNames, header: "MARK: - Accidentals (full set)", file: "SMuFLCodepoints+Accidentals.swift")
try emit(lineNames, header: "MARK: - Vibrato / glissando lines", file: "SMuFLCodepoints+Lines.swift")
```

> Populate the two `/* … */` name lists from Appendix A.1 / A.2 (the unique set of SymId names appearing in those tables). The `lineNames` list is complete above.

- [ ] **Step 3: Run the generator**

Run: `swift run GenSMuFLTables`
Expected: prints `wrote SMuFLCodepoints+Noteheads.swift: N glyphs` etc., and exits 0. If it prints `MISSING in subset: […]`, widen the `keep()` ranges in Task 0.1's Python and re-extract.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: compiles. (No behaviour change yet; just new constants.)

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/GenSMuFLTables/main.swift Sources/SheetMusicLayout/Engraving/SMuFLCodepoints+Noteheads.swift Sources/SheetMusicLayout/Engraving/SMuFLCodepoints+Accidentals.swift Sources/SheetMusicLayout/Engraving/SMuFLCodepoints+Lines.swift
git commit -m "build: generate full SMuFL notehead/accidental/line codepoints"
```

---

## Phase 1 — Notehead types (all groups)

### Task 1.1: `NoteHeadGroup` enum + token resolver + glyph table

**Files:**
- Create: `Sources/SheetMusicLayout/Engraving/NoteHeadGroup.swift`
- Test: `Tests/SheetMusicTests/NoteHeadGroupTests.swift`

**Interfaces:**
- Produces:
  - `enum NoteHeadGroup: String, CaseIterable, Sendable` with one case per MuseScore group; `rawValue` = the MS4 `<head>` token (Appendix A.3).
  - `static func from(token: String) -> NoteHeadGroup?` (nil for unknown / `"custom"`).
  - `enum NoteHeadKind { case whole, half, quarter, doubleWhole }`.
  - `static func symName(group: NoteHeadGroup, kind: NoteHeadKind, stemUp: Bool) -> String` — the SymId name (Appendix A.1), `"noSym"` for absent cells.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicLayout

@Suite struct NoteHeadGroupTests {
    @Test func tokenResolves() {
        #expect(NoteHeadGroup.from(token: "xcircle") == .xcircle)
        #expect(NoteHeadGroup.from(token: "altbrevis") == .brevisAlt)
        #expect(NoteHeadGroup.from(token: "a-sharp-name") == .aSharpName)
        #expect(NoteHeadGroup.from(token: "custom") == nil)
        #expect(NoteHeadGroup.from(token: "bogus") == nil)
    }

    @Test func glyphNames() {
        #expect(NoteHeadGroup.symName(group: .xcircle, kind: .quarter, stemUp: false) == "noteheadCircleX")
        #expect(NoteHeadGroup.symName(group: .normal, kind: .whole, stemUp: false) == "noteheadWhole")
        // FA flips triangle-right (down stem) vs triangle-left (up stem).
        #expect(NoteHeadGroup.symName(group: .fa, kind: .quarter, stemUp: false) == "noteShapeTriangleRightBlack")
        #expect(NoteHeadGroup.symName(group: .fa, kind: .quarter, stemUp: true) == "noteShapeTriangleLeftBlack")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter NoteHeadGroupTests`
Expected: FAIL (no `NoteHeadGroup`).

- [ ] **Step 3: Implement `NoteHeadGroup.swift`**

Transcribe Appendix A.3 (token → case) and Appendix A.1 (group×kind×stem → SymId name). Structure: the enum with `rawValue` tokens; `from(token:)` = `NoteHeadGroup(rawValue:)` returning nil for `"custom"`/unknown; a `private static let downStem: [NoteHeadGroup: [String]]` (4-element arrays in `whole,half,quarter,doubleWhole` order) and `upStem` overriding only the 4 differing groups (`largeArrow`, `slash`, `largeDiamond`, `fa`); `symName(...)` indexes them. Add `/// C++: src/engraving/dom/note.cpp:89-322` and `…/types/typesconv.cpp:1145-1235` provenance. Split into `NoteHeadGroup.swift` + `NoteHeadGroup+Table.swift` if > 300 lines.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter NoteHeadGroupTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicLayout/Engraving/NoteHeadGroup.swift Tests/SheetMusicTests/NoteHeadGroupTests.swift
git commit -m "feat(layout): NoteHeadGroup token resolver + SymId glyph table"
```

### Task 1.2: Rewrite `NoteheadGlyph.codepoint` to use the table

**Files:**
- Modify: `Sources/SheetMusicLayout/Engraving/NoteheadGlyph.swift`
- Modify call sites: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Chord.swift` (the `noteheadGlyph(for:headType:)` helper ~line 80, 206), `Sources/SheetMusicUI/Rendering/NoteheadRenderer.swift:14`, `Sources/SheetMusicAndroidJNI/LayoutBridge+Chord.swift` (notehead glyph fetch)
- Test: `Tests/SheetMusicTests/NoteheadGlyphTests.swift`

**Interfaces:**
- Consumes: `NoteHeadGroup`, `SMuFLCodepoint.<symName>` (Phase 0/1).
- Produces: `static func codepoint(duration: NoteDuration, headType: String?, stemUp: Bool) -> UInt32`. Unknown/`nil` headType → standard family (unchanged fallback). The `stemUp` parameter defaults are NOT added — every caller passes it.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicLayout

@Suite struct NoteheadGlyphTests {
    @Test func xcircleNowRenders() {
        let cp = NoteheadGlyph.codepoint(duration: .quarter, headType: "xcircle", stemUp: false)
        #expect(cp == SMuFLCodepoint.noteheadCircleX)
        #expect(cp != SMuFLCodepoint.noteheadBlack)   // no longer falls back
    }
    @Test func unknownStillFallsBack() {
        #expect(NoteheadGlyph.codepoint(duration: .quarter, headType: "totally-unknown", stemUp: false) == SMuFLCodepoint.noteheadBlack)
    }
    @Test func slashAndShapeNotes() {
        #expect(NoteheadGlyph.codepoint(duration: .half, headType: "slash", stemUp: false) == SMuFLCodepoint.noteheadSlashWhiteHalf)
        #expect(NoteheadGlyph.codepoint(duration: .quarter, headType: "do", stemUp: false) == SMuFLCodepoint.noteShapeTriangleUpBlack)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter NoteheadGlyphTests`
Expected: FAIL (signature mismatch / wrong codepoint).

- [ ] **Step 3: Rewrite `NoteheadGlyph`**

```swift
import SheetMusicCore

public enum NoteheadGlyph {
    public static func codepoint(
        duration: NoteDuration, headType: String?, stemUp: Bool,
    ) -> UInt32 {
        let kind: NoteHeadGroup.NoteHeadKind
        switch duration {
        case .whole: kind = .whole
        case .half: kind = .half
        default: kind = .quarter
        }
        if let token = headType, let group = NoteHeadGroup.from(token: token) {
            let name = NoteHeadGroup.symName(group: group, kind: kind, stemUp: stemUp)
            if name != "noSym", let cp = SMuFLCodepoint.byName(name) { return cp }
        }
        // Fallback: standard family.
        switch kind {
        case .whole: return SMuFLCodepoint.noteheadWhole
        case .half: return SMuFLCodepoint.noteheadHalf
        default: return SMuFLCodepoint.noteheadBlack
        }
    }
}
```

Add `SMuFLCodepoint.byName(_:) -> UInt32?` in `SMuFLGlyphName.swift` — a switch (or generated dictionary) over every referenced SymId name → its constant. Generate it in the same `GenSMuFLTables` run (extend the generator to also emit a `byName` switch into `SMuFLGlyphName.swift`), or hand-write the small set used by tests plus a `default: nil`. **Update the generator (Task 0.2) to also emit `byName`** so it stays exhaustive; re-run `swift run GenSMuFLTables`.

- [ ] **Step 4: Update the three call sites to pass `stemUp`**

In each call site the chord/notehead context already knows stem direction (the layout computed it). Pass it through. Example (`ScoreLayerBuilder+Chord.swift`): `noteheadGlyph(for: baseDur, headType: n.headType, stemUp: chord.stemUp)`. Thread a `stemUp: Bool` into the local `noteheadGlyph` helper. For `LayoutBridge+Chord.swift` and `NoteheadRenderer.swift`, do the same. If a site lacks stem direction, pass the chord's resolved stem-up bool from `LayoutChordNote`/`LayoutElement.chord`.

- [ ] **Step 5: Run tests + build**

Run: `swift test --filter NoteheadGlyphTests`  → PASS
Run: `swift build`  → compiles (all call sites updated).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Engraving/NoteheadGlyph.swift Sources/SheetMusicLayout/Engraving/SMuFLGlyphName.swift Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Chord.swift Sources/SheetMusicUI/Rendering/NoteheadRenderer.swift Sources/SheetMusicAndroidJNI/LayoutBridge+Chord.swift Sources/GenSMuFLTables/main.swift Tests/SheetMusicTests/NoteheadGlyphTests.swift
git commit -m "feat(layout): render all notehead groups via NoteHeadGroup table"
```

### Task 1.3: Normalize decoder head tokens to MS4 + diagnostic

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Note.swift` (`decodeHeadType`, ~line 71-93)
- Test: `Tests/SheetMusicTests/HeadTypeDecodeTests.swift`

**Interfaces:**
- Consumes: `mscxDecoderWarn(code:message:location:)`.
- Produces: `decodeHeadType` returns MS4 tokens for all MS2 codes; warns on unknown.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicMSCX
@testable import SheetMusicCore

@Suite struct HeadTypeDecodeTests {
    @Test func ms2CodeNormalizesToMS4Token() throws {
        // MS2 code 13 was "alt-brevis"; MS4 token is "altbrevis".
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc><head>13</head></Note>"
        let note = try Note.decode(XMLTreeParser.parse(xml))
        #expect(note.headType == "altbrevis")
    }
    @Test func unknownCodeWarnsAndDrops() throws {
        let result = try MSCXDecoderWarn.capture {
            let xml = "<Note><pitch>60</pitch><tpc>14</tpc><head>99</head></Note>"
            _ = try Note.decode(XMLTreeParser.parse(xml))
        }
        #expect(result.contains { $0.code == "mscx.note.unsupportedHeadType" })
    }
}
```

> `MSCXDecoderWarn.capture { … }` is a test helper that installs an `MSCXDiagnosticCollector` in `MSCXParserContext` for the closure and returns the collected `[ScoreDiagnostic]`. If one doesn't exist, add it to `Tests/SheetMusicTests/Helpers/`. Adapt `XMLTreeParser.parse` to the actual helper used by sibling decode tests.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter HeadTypeDecodeTests`  → FAIL.

- [ ] **Step 3: Fix `decodeHeadType`**

Map MS2 codes 0–13 to MS4 tokens (Appendix A.4 — note `13 → "altbrevis"`, `6 → "xcircle"`). For unknown integer codes and MS3 strings that are not a known group token nor `"custom"`, call `mscxDecoderWarn(code: "mscx.note.unsupportedHeadType", message: "…")` and return `nil`. Keep `"custom"` passing through silently (it's intentional, not unsupported). The "known group token" set is the MS4 token list (Appendix A.3); define it as a `Set<String>` constant in the decoder.

- [ ] **Step 4: Run + build**

Run: `swift test --filter HeadTypeDecodeTests`  → PASS
Run: `swift build`

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Note.swift Tests/SheetMusicTests/HeadTypeDecodeTests.swift Tests/SheetMusicTests/Helpers/
git commit -m "feat(mscx): normalize MS2 head codes to MS4 tokens + unsupported diagnostic"
```

---

## Phase 2 — Notehead size (small / cue)

### Task 2.1: `Note.isSmall` + decode `<small>`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Note.swift` (add field + init param)
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Note.swift` (decode `<small>`)
- Test: `Tests/SheetMusicTests/SmallNoteTests.swift`

**Interfaces:**
- Produces: `Note.isSmall: Bool` (default `false`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicMSCX
@testable import SheetMusicCore

@Suite struct SmallNoteTests {
    @Test func decodesSmallFlag() throws {
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc><small>1</small></Note>"
        #expect(try Note.decode(XMLTreeParser.parse(xml)).isSmall == true)
    }
    @Test func defaultsFalse() throws {
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc></Note>"
        #expect(try Note.decode(XMLTreeParser.parse(xml)).isSmall == false)
    }
}
```

- [ ] **Step 2: Run → FAIL.** `swift test --filter SmallNoteTests`

- [ ] **Step 3: Implement**

Add `public var isSmall: Bool` to `Note` (init param `isSmall: Bool = false`, last before the body sets `elementProperties`). In `Note.decode`, set `isSmall = node.first("small")?.text == "1"`. (Chord-level `<small>` propagation is Task 2.2.)

- [ ] **Step 4: Run → PASS.** `swift test --filter SmallNoteTests`; then `swift build`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/Note.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Note.swift Tests/SheetMusicTests/SmallNoteTests.swift
git commit -m "feat(core): Note.isSmall decoded from MSCX <small>"
```

### Task 2.2: Chord `<small>` propagation + layout mag

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift` (propagate `<small>` to notes) — find the chord decoder file
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift` (add `mag` to the chord element if not present)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` (set mag when any note `isSmall`)
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Chord.swift` (scale metrics by mag), `Sources/SheetMusicAndroidJNI/LayoutBridge+Chord.swift`
- Test: `Tests/SheetMusicTests/SmallNoteLayoutTests.swift`

**Interfaces:**
- Consumes: `Note.isSmall`, grace-note mag precedent (`LayoutElement.graceChord.mag`, `GraceChordRenderer` scaled-metrics pattern).
- Produces: `LayoutElement.chord` carries `mag: CGFloat` (1.0 = normal; 0.7 = small). `smallNoteMag = 0.7` constant.

- [ ] **Step 1: Write the failing test** (layout produces reduced mag for a small chord)

```swift
import Testing
@testable import SheetMusicLayout
@testable import SheetMusicCore

@Suite struct SmallNoteLayoutTests {
    @Test func smallChordGetsReducedMag() {
        // Build a one-chord measure with isSmall == true via the existing
        // layout test harness, run LayoutEngine, find the .chord element.
        let mag = smallChordMagInFirstChord(makeSmallChordScore())
        #expect(mag == 0.7)
    }
    @Test func normalChordMagIsOne() {
        #expect(smallChordMagInFirstChord(makeNormalChordScore()) == 1.0)
    }
}
```

> `makeSmallChordScore()` / `smallChordMagInFirstChord(...)` are local helpers built on the existing layout test scaffolding (mirror an existing `LayoutEngine` test in `Tests/SheetMusicTests/`). If the chord element already exposes mag, assert on it; otherwise this drives adding it.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement**

(a) In the chord decoder, if `<Chord><small>` is `1`, set every decoded note's `isSmall = true`. (b) Add `mag: CGFloat = 1.0` to `LayoutElement`'s chord case (mirror `graceChord`'s `mag`). (c) In `LayoutEngine+Placement`, when building the chord element, set `mag = chord.notes.contains { $0.isSmall } ? options.smallNoteMag : 1.0`; add `smallNoteMag: CGFloat = 0.7` to the layout options (or a constant). (d) In `ScoreLayerBuilder+Chord` (and `LayoutBridge+Chord`), when `mag != 1.0`, build scaled `StaffMetrics(staffSize: metrics.staffHeight * mag)` for the notehead/leger glyph sizing, exactly like `GraceChordRenderer.swift:38`.

- [ ] **Step 4: Run → PASS;** `swift build`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(layout): small/cue noteheads at 0.7 mag (chord + note <small>)"
```

---

## Phase 3 — Accidentals (all types + bracket)

### Task 3.1: Expand `Accidental` to the full `AccidentalType` set

**Files:**
- Create: `Sources/SheetMusicCore/Score/AccidentalType.swift` (the expanded enum; replaces `Accidental.swift`)
- Create: `Sources/SheetMusicCore/Score/AccidentalOffsets.swift` (semitone offsets)
- Delete: `Sources/SheetMusicCore/Score/Accidental.swift` (content moves)
- Test: `Tests/SheetMusicTests/AccidentalDecodeTests.swift`

**Interfaces:**
- Produces:
  - `enum Accidental: String, Sendable, CaseIterable` — one case per MuseScore `AccidentalType` (Appendix A.5). Keep the existing case **names** `sharp`/`flat`/`natural`/`doubleSharp`/`doubleFlat` so existing code compiles; add the rest.
  - `init?(mscxSubtype: String)` — maps the SMuFL SymId-name token → case (Appendix A.5). nil for unknown.
  - `var mscxSubtype: String` — inverse (for the encoder).
  - `var semitoneOffset: Int` in `AccidentalOffsets.swift`.
  - `enum AccidentalBracket: Int, Sendable { case none = 0, parenthesis = 1, bracket = 2 }`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicCore

@Suite struct AccidentalDecodeTests {
    @Test func standardRoundTrips() {
        #expect(Accidental(mscxSubtype: "accidentalSharp") == .sharp)
        #expect(Accidental.sharp.mscxSubtype == "accidentalSharp")
    }
    @Test func quarterToneDecodes() {
        #expect(Accidental(mscxSubtype: "accidentalQuarterToneFlatStein") == .mirroredFlat)
    }
    @Test func unknownIsNil() {
        #expect(Accidental(mscxSubtype: "accidentalBogus") == nil)
    }
    @Test func semitoneOffsets() {
        #expect(Accidental.sharp.semitoneOffset == 1)
        #expect(Accidental.doubleFlat.semitoneOffset == -2)
        #expect(Accidental.mirroredFlat.semitoneOffset == 0)   // quarter-tone → integer part
    }
    @Test func brackets() {
        #expect(AccidentalBracket(rawValue: 1) == .parenthesis)
    }
}
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** the expanded enum (Appendix A.5: case name ↔ SymId-name subtype) + `AccidentalBracket` + `semitoneOffset` (Appendix A.5 offset column; microtonal → integer part). Add `/// C++: src/engraving/dom/accidental.{h,cpp}` provenance. Split across the two files to stay under 300 lines. The `init?(mscxSubtype:)` and `mscxSubtype` are a paired switch keyed on the SymId-name token.

- [ ] **Step 4: Run → PASS;** `swift build` (will FAIL to build — exhaustive switches elsewhere now non-exhaustive; that's Task 3.2/3.3. Build the **test module filter** only: `swift test --filter AccidentalDecodeTests` may also fail to link until 3.2/3.3. If so, do 3.1+3.2+3.3 as one commit.)

> **Note:** Because expanding a public enum breaks every exhaustive switch over it, Tasks 3.1–3.3 must land together (one green `swift build`). Treat them as one reviewable unit; commit once at the end of 3.3.

### Task 3.2: Update exhaustive switches (PitchSpelling, encoder)

**Files:**
- Modify: `Sources/SheetMusicCore/PitchSpelling.swift:82-89` (`semitoneShift`)
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift:175-182`

- [ ] **Step 1:** In `PitchSpelling.semitoneShift`, replace the 5-case switch with `accidental.semitoneOffset` (now defined for all cases).
- [ ] **Step 2:** In `MSCXEncoder+Note`, replace the 5-case accidental→subtype switch with `accidental.mscxSubtype`; also encode `<bracket>` from `note.accidentalBracket` when `!= .none` (field added in Task 3.3).
- [ ] **Step 3:** Confirm `LayoutHarmony.HarmonyAccidental` (`LayoutHarmony.swift:78-84`) is a **separate** enum (chord symbols) — no change needed. `MusicXMLDecoder+Note` uses `default: return nil` — no change needed.

### Task 3.3: `Note.accidentalBracket` + decode `<subtype>`/`<bracket>`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Note.swift` (add `accidentalBracket`)
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Note.swift` (decode subtype via new init, decode `<bracket>`, warn on unknown subtype)
- Test: `Tests/SheetMusicTests/AccidentalBracketDecodeTests.swift`

**Interfaces:**
- Produces: `Note.accidentalBracket: AccidentalBracket` (default `.none`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicMSCX
@testable import SheetMusicCore

@Suite struct AccidentalBracketDecodeTests {
    @Test func decodesSubtypeAndBracket() throws {
        let xml = """
        <Note><pitch>61</pitch><tpc>20</tpc>\
        <Accidental><subtype>accidentalSharp</subtype><bracket>1</bracket></Accidental></Note>
        """
        let note = try Note.decode(XMLTreeParser.parse(xml))
        #expect(note.accidental == .sharp)
        #expect(note.accidentalBracket == .parenthesis)
    }
    @Test func unknownSubtypeWarns() throws {
        let diags = try MSCXDecoderWarn.capture {
            let xml = "<Note><pitch>61</pitch><tpc>20</tpc><Accidental><subtype>accidentalBogus</subtype></Accidental></Note>"
            _ = try Note.decode(XMLTreeParser.parse(xml))
        }
        #expect(diags.contains { $0.code == "mscx.accidental.unsupportedSubtype" })
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — add `accidentalBracket` to `Note` (init default `.none`). In `Note.decode`: `accidental = Accidental(mscxSubtype: subtype)`; if subtype present but `accidental == nil`, `mscxDecoderWarn(code: "mscx.accidental.unsupportedSubtype", …)`; decode `<bracket>` int → `AccidentalBracket(rawValue:) ?? .none`.
- [ ] **Step 4: Run all of Phase 3** — `swift build` (now exhaustive switches fixed) then `swift test --filter Accidental`. Both green.
- [ ] **Step 5: Commit (Tasks 3.1–3.3 together)**

```bash
git add -A
git commit -m "feat: full AccidentalType set + parenthesis/bracket + decode diagnostics"
```

### Task 3.4: Rewrite `AccidentalGlyph` (full table + enclosure)

**Files:**
- Modify: `Sources/SheetMusicLayout/Engraving/AccidentalGlyph.swift`
- Test: `Tests/SheetMusicTests/AccidentalGlyphTests.swift`

**Interfaces:**
- Consumes: `Accidental`, `AccidentalBracket`, `SMuFLCodepoint.byName`.
- Produces:
  - `static func codepoint(_ accidental: Accidental) -> UInt32` — full table (Appendix A.5 SymId-name → codepoint).
  - `static func enclosure(_ bracket: AccidentalBracket) -> (left: UInt32, right: UInt32)?` — nil for `.none`; paren → `(accidentalParensLeft, accidentalParensRight)`; bracket → `(accidentalBracketLeft, accidentalBracketRight)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicLayout
@testable import SheetMusicCore

@Suite struct AccidentalGlyphTests {
    @Test func standardUnchanged() {
        #expect(AccidentalGlyph.codepoint(.sharp) == 0xE262)
        #expect(AccidentalGlyph.codepoint(.doubleFlat) == 0xE264)
    }
    @Test func quarterToneMapsToSmuflName() {
        #expect(AccidentalGlyph.codepoint(.mirroredFlat) == SMuFLCodepoint.accidentalQuarterToneFlatStein)
    }
    @Test func enclosureGlyphs() {
        #expect(AccidentalGlyph.enclosure(.none) == nil)
        let p = AccidentalGlyph.enclosure(.parenthesis)
        #expect(p?.left == 0xE26A)
        #expect(p?.right == 0xE26B)
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `codepoint` via `SMuFLCodepoint.byName(accidental.mscxSubtype)` (the mscx `<subtype>` string **is** the SMuFL SymId-name, so no separate accessor is needed); `enclosure` returns the constant pair. Keep the function total (every `Accidental` resolves; if `byName` returns nil, fall back to `accidentalNatural` and that's a generator-coverage bug caught by the sync test in Phase 6).
- [ ] **Step 4: Run → PASS;** `swift build`.
- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicLayout/Engraving/AccidentalGlyph.swift Sources/SheetMusicCore/Score/AccidentalType.swift Tests/SheetMusicTests/AccidentalGlyphTests.swift
git commit -m "feat(layout): full accidental glyph table + bracket enclosure"
```

### Task 3.5: Render accidental enclosure + measured-width placement

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Chord.swift` (`drawAccidental`, ~line 121-128, 224-228)
- Modify: `Sources/SheetMusicUI/Rendering/AccidentalRenderer.swift` (parity)
- Modify: `Sources/SheetMusicAndroidJNI/LayoutBridge+Chord.swift:172` (offset + enclosure)
- Test: covered by visual fixture (Phase 7); add a geometry unit test if a measurable helper is introduced.

**Interfaces:**
- Consumes: `AccidentalGlyph.enclosure`, `FontMetricsProvider` advance widths.

- [ ] **Step 1:** Replace the hardcoded `origin.x - metrics.sp * 1.2` accidental offset with a measured offset: query the accidental glyph's advance width from the metrics provider (the same provider used for noteheads), and place the accidental so its right edge sits a fixed small gap (e.g. `0.16 sp`) left of the notehead's left edge. When `accidentalBracket != .none`, also lay out the left/right enclosure glyphs flanking the accidental (left glyph further left by its own advance, right glyph just right of the accidental), widening the total left offset accordingly.
- [ ] **Step 2:** Mirror in `AccidentalRenderer` (Canvas) and `LayoutBridge+Chord` (Android — emit the extra enclosure `.glyph` ops; scale by `mag`).
- [ ] **Step 3:** `swift build`; `swift test` (no regressions in existing accidental layout tests).
- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(render): accidental enclosure glyphs + measured-width placement"
```

---

## Phase 4 — Vibrato

### Task 4.1: `Spanner.Kind.vibrato` + payload + decode

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Spanner.swift` (add `.vibrato` case + `VibratoPayload` + `vibrato` field)
- Create: `Sources/SheetMusicCore/Score/VibratoType.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift`
- Modify exhaustive switches: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift` (`isBelowStaff` ~324, `layoutKind` ~480)
- Test: `Tests/SheetMusicTests/VibratoDecodeTests.swift`

**Interfaces:**
- Produces: `enum VibratoType: String, Sendable { case guitarVibrato = "guitarVibrato", guitarVibratoWide = "guitarVibratoWide", sawtooth = "vibratoSawtooth", sawtoothWide = "vibratoSawtoothWide" }`; `Spanner.VibratoPayload { var type: VibratoType }`; `Spanner.Kind.vibrato`; `Spanner.vibrato: VibratoPayload?`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicMSCX
@testable import SheetMusicCore

@Suite struct VibratoDecodeTests {
    @Test func decodesVibratoSubtype() throws {
        let xml = "<Spanner type=\"Vibrato\"><Vibrato><subtype>guitarVibrato</subtype></Vibrato><next><location><measures>1</measures></location></next></Spanner>"
        let sp = try Spanner.decode(XMLTreeParser.parse(xml))   // adapt to actual decode entry
        #expect(sp?.kind == .vibrato)
        #expect(sp?.vibrato?.type == .guitarVibrato)
    }
    @Test func unknownSubtypeWarns() throws {
        let diags = try MSCXDecoderWarn.capture {
            let xml = "<Spanner type=\"Vibrato\"><Vibrato><subtype>bogus</subtype></Vibrato></Spanner>"
            _ = try Spanner.decode(XMLTreeParser.parse(xml))
        }
        #expect(diags.contains { $0.code == "mscx.vibrato.unknownSubtype" })
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — add `.vibrato` to `Spanner.Kind`, `VibratoType` + `VibratoPayload`, `Spanner.vibrato` field. In `MSCXDecoder+Spanner`, when `type == "Vibrato"`, set `kind = .vibrato` and decode `<Vibrato><subtype>` → `VibratoType(rawValue:)`; warn `mscx.vibrato.unknownSubtype` + default to `.guitarVibrato` if unknown. Update the two `Spanner.Kind` exhaustive switches: `isBelowStaff` → vibrato is above staff (`false`); `layoutKind` → `.vibrato` (Layout case added in Task 4.2). **This task will not build until 4.2 adds the Layout case — land 4.1 + 4.2 together.**

### Task 4.2: `LayoutElement.SpannerKind.vibrato` + geometry + render

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift:272-280` (`SpannerKind.vibrato` + carry payload)
- Modify: `Sources/SheetMusicLayout/Engraving/SpannerGeometry.swift` (add `vibrato` glyph-run geometry)
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Spanners.swift:23-57` (CALayer)
- Modify: `Sources/SheetMusicUI/Rendering/SpannerRenderer.swift:17-47` (Canvas)
- Modify: `Sources/SheetMusicAndroidJNI/LayoutBridge+Engraving.swift:454-593` (Android)
- Test: `Tests/SheetMusicTests/VibratoGeometryTests.swift`

**Interfaces:**
- Consumes: `VibratoType`, `SMuFLCodepoint.{guitarVibratoStroke,guitarWideVibratoStroke,wiggleSawtooth,wiggleSawtoothWide}`.
- Produces: `SpannerGeometry.vibratoGlyphRun(from:to:type:sp:advance:) -> (codepoint: UInt32, origins: [CGPoint])` — count = `lrint((width - advance)/advance)` copies; `LayoutElement.SpannerKind.vibrato(VibratoType)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicLayout

@Suite struct VibratoGeometryTests {
    @Test func glyphCountAndCodepoint() {
        let run = SpannerGeometry.vibratoGlyphRun(
            from: .zero, to: CGPoint(x: 40, y: 0), type: .guitarVibrato, sp: 8, advance: 8)
        #expect(run.codepoint == SMuFLCodepoint.guitarVibratoStroke)
        #expect(run.origins.count == 4)   // lrint((40-8)/8) = 4
    }
    @Test func sawtoothUsesWiggleGlyph() {
        let run = SpannerGeometry.vibratoGlyphRun(
            from: .zero, to: CGPoint(x: 40, y: 0), type: .sawtooth, sp: 8, advance: 8)
        #expect(run.codepoint == SMuFLCodepoint.wiggleSawtooth)
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the geometry (`/// C++: vibrato.cpp:49-67`, `tlayout.cpp:6447-6462`), map `VibratoType` → codepoint, compute evenly-spaced origins along the line. Add `SpannerKind.vibrato(VibratoType)` to `LayoutElement`. In `LayoutEngine+Spanners.layoutKind`, return `.vibrato(payload.type)`. In all three renderers, add the `.vibrato` case drawing `run.origins.count` glyph copies (CALayer/Canvas: draw glyph; Android: emit `.glyph` ops). Use the metrics provider's advance for the chosen glyph as the `advance` arg.
- [ ] **Step 4: Run → PASS;** `swift build`; `swift test`.
- [ ] **Step 5: Commit (4.1 + 4.2 together)**

```bash
git add -A
git commit -m "feat: render vibrato lines (4 subtypes) as repeated SMuFL wiggle glyphs"
```

---

## Phase 5 — Wavy glissando

### Task 5.1: Wavy glissando as repeated `wiggleGlissando`

**Files:**
- Modify: `Sources/SheetMusicLayout/Engraving/GlissandoGeometry.swift` (`linePoints` wavy branch → glyph-run helper)
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Glissando.swift` (CALayer)
- Modify: `Sources/SheetMusicUI/Rendering/GlissandoRenderer.swift` (Canvas)
- Modify: `Sources/SheetMusicAndroidJNI/LayoutBridge+Glissando.swift` (Android)
- Test: `Tests/SheetMusicTests/GlissandoWavyTests.swift`

**Interfaces:**
- Consumes: `SMuFLCodepoint.wiggleGlissando`.
- Produces: `GlissandoGeometry.wavyGlyphRun(length:advance:) -> (count: Int, startX: CGFloat)` — `count = floor(length/advance)`, `startX = (length - count*advance)/2` (centered). Straight rendering unchanged.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicLayout

@Suite struct GlissandoWavyTests {
    @Test func centeredGlyphRun() {
        let run = GlissandoGeometry.wavyGlyphRun(length: 50, advance: 12)
        #expect(run.count == 4)               // floor(50/12)
        #expect(abs(run.startX - 1.0) < 0.001) // (50 - 48)/2
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `wavyGlyphRun` (`/// C++: tdraw.cpp:1585-1596`). In both Apple renderers, when `wavy`, draw `count` copies of `wiggleGlissando` starting at `startX` along the rotated local frame (vertically centered on the line), instead of the zigzag polyline; keep the straight branch and the text label logic. In Android, emit `count` `.glyph` ops along the (already rotated) glissando path. Remove the now-unused zigzag amplitude code in `GlissandoGeometry.linePoints` only if nothing else uses it (otherwise leave the straight path alone).
- [ ] **Step 4: Run → PASS;** `swift build`; `swift test`.
- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(render): wavy glissando uses repeated wiggleGlissando glyph"
```

---

## Phase 6 — Diagnostics sync test

### Task 6.1: MSCX-known ↔ Layout-renderable sync test

**Files:**
- Create: `Tests/SheetMusicTests/RenderCoverageSyncTests.swift`
- Possibly Modify: expose the decoder's known-token sets (`internal` + `@testable`) in `MSCXDecoder+Note` / `MSCXDecoder+Spanner`.

**Interfaces:**
- Consumes: the decoder's known-headType-token set, known-accidental-subtype set, known-vibrato-subtype set; `NoteHeadGroup.allCases`, `Accidental.allCases`, `VibratoType.allCases`.

- [ ] **Step 1: Write the test**

```swift
import Testing
@testable import SheetMusicMSCX
@testable import SheetMusicLayout
@testable import SheetMusicCore

@Suite struct RenderCoverageSyncTests {
    @Test func everyKnownHeadTokenRenders() {
        for token in MSCXDecoder.knownHeadTokens {
            #expect(NoteHeadGroup.from(token: token) != nil, "head token \(token) not renderable")
        }
    }
    @Test func everyAccidentalResolvesToGlyph() {
        for acc in Accidental.allCases {
            #expect(SMuFLCodepoint.byName(acc.mscxSubtype) != nil, "accidental \(acc) has no glyph")
        }
    }
    @Test func everyVibratoTypeHasGlyph() {
        for t in VibratoType.allCases {
            let run = SpannerGeometry.vibratoGlyphRun(from: .zero, to: CGPoint(x: 40, y: 0), type: t, sp: 8, advance: 8)
            #expect(run.codepoint != 0)
        }
    }
}
```

- [ ] **Step 2: Run → may FAIL** if a token lacks a glyph (generator missed a name) — fix by widening the glyphnames subset + regenerating, or correcting the table. Iterate until green.
- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test: assert decoder-known subtypes are all renderable (sync guard)"
```

---

## Phase 7 — Fixture + verification

### Task 7.1: Author the `.mscz` fixture and copy to Desktop

**Files:**
- Create: `Scripts/build-coverage-fixture.sh` (+ a helper that authors the `.mscx` and zips it)
- Output: `~/Desktop/notation-coverage-fixture.mscz`

- [ ] **Step 1:** Hand-author a MuseScore-4 `.mscx` (single treble instrument, several measures) containing: a representative spread of notehead groups across whole/half/quarter (normal, cross, xcircle, withx, plus, diamond, slash, slashed1, triangle-up/down, circled, a shape note, a named-pitch head, brevis-alt); a couple of small/cue notes (`<small>1</small>`); accidentals from each family (standard ×5, a quarter-tone e.g. `accidentalQuarterToneFlatStein`, one parenthesized `<bracket>1</bracket>`, one bracketed `<bracket>2</bracket>`, one exotic e.g. a Sagittal); a `<Spanner type="Vibrato">` for each of the 4 subtypes; a straight and a wavy glissando between note pairs. Use a known-good MS4 skeleton (`<museScore version="4.50"><Score><Division>480</Division>…`).
- [ ] **Step 2:** Validate it parses with our own parser:

```bash
swift run RenderPreviews --parse ~/Desktop/notation-coverage-fixture.mscz   # or the package's parse smoke path
```

Confirm zero `malformedScore` throws and that `parseWithDiagnostics` reports **no** `unsupported*` warnings (every element we put in is now supported).
- [ ] **Step 3:** Copy to Desktop (the script does this) and **ask the user to open it in MuseScore** for the side-by-side. Render it in `SheetMusicExampleMac` for our side.
- [ ] **Step 4: Commit** the script (the `.mscz` is a Desktop deliverable; commit a copy under `docs/` only if the user wants it tracked — do not place it under `Tests/.../Resources`).

```bash
git add Scripts/build-coverage-fixture.sh
git commit -m "test: coverage fixture generator (noteheads/accidentals/vibrato/gliss)"
```

### Task 7.2: Full verification

- [ ] **Step 1:** `swift test` — 100% green (incl. `MidiExportTests`).
- [ ] **Step 2:** `swiftlint --quiet Sources Tests` — 0 warnings (generated files included; if a generated file trips a rule, add a scoped `// swiftlint:disable` header in the generator output).
- [ ] **Step 3:** `Scripts/gate-android-tests.sh` — ensure new Apple-only tests are gated.
- [ ] **Step 4:** Regenerate + build the example app:

```bash
cd Examples/Apple && xcodegen generate
xcodebuild -project Examples/Apple/SheetMusicExample.xcodeproj -scheme SheetMusicExample -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Build the Mac example scheme too (public-enum changes ripple into the app). Both must build.
- [ ] **Step 5:** (If Android toolchain present) `Scripts/preflight.sh` or at least `SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28` — the Android JNI changes compile.
- [ ] **Step 6:** Visual check in `SheetMusicExampleMac`; user compares against MuseScore. Iterate on glyph/placement bugs.

---

## Phase 8 — Folino proposal (documentation only — no Folino code change)

### Task 8.1: Write the Folino fix proposal

**Files:**
- Create: `docs/folino-unsupported-element-reporting-proposal.md`

- [ ] **Step 1:** Document, in English: (a) the traced root cause — Folino's `LiveScoreFileGateway` reports only `.warning` `ScoreDiagnostic`s from `parseWithDiagnostics`, and swift-sheet-music previously emitted none for notehead/accidental/vibrato fallbacks; (b) the upstream fix shipped here (new `mscx.note.unsupportedHeadType` / `mscx.accidental.unsupportedSubtype` / `mscx.vibrato.unknownSubtype` diagnostics) means Folino reports genuinely-unsupported elements **after bumping the dependency, with no Folino code change**; (c) the separate gap that `LiveScoreFileGateway` returns `[]` for MusicXML/MXL/MIDI (out of scope, noted for future). Explicitly state: **do not modify Folino in this work** — proposal only.
- [ ] **Step 2: Commit**

```bash
git add docs/folino-unsupported-element-reporting-proposal.md
git commit -m "docs: Folino unsupported-element reporting root cause + proposal"
```

---

## Appendix A — Transcription data (from MuseScore, studied not copied)

> These tables were extracted from `~/Developer/musescore/MuseScore` during the
> design survey (source lines cited). They are the contract for the generator
> (Task 0.2) and the enums/tables (Tasks 1.1, 3.1). **Cross-check any cell
> against the cited MuseScore line before relying on it** — the Phase 6 sync
> test and the known-codepoint unit tests catch a mis-transcribed/renamed
> glyph. `noteHeadGroup` enum case names below are the idiomatic Swift names
> to use; the C++ name goes in a `/// C++:` doc comment.

### A.1 + A.3 Notehead groups — `note.cpp:89-322`, tokens `typesconv.cpp:1145-1235`

Down-stem `noteHeads[0]`, columns `{whole, half, quarter, doubleWhole}`. Swift
case ← MS4 token ← SymIds. (`HEAD_CUSTOM`/`custom` excluded — passes through.)

| case (token) | whole | half | quarter | doubleWhole |
|---|---|---|---|---|
| normal (`normal`) | noteheadWhole | noteheadHalf | noteheadBlack | noteheadDoubleWhole |
| cross (`cross`) | noteheadXWhole | noteheadXHalf | noteheadXBlack | noteheadXDoubleWhole |
| plus (`plus`) | noteheadPlusWhole | noteheadPlusHalf | noteheadPlusBlack | noteheadPlusDoubleWhole |
| xcircle (`xcircle`) | noteheadCircleXWhole | noteheadCircleXHalf | noteheadCircleX | noteheadCircleXDoubleWhole |
| withX (`withx`) | noteheadWholeWithX | noteheadHalfWithX | noteheadVoidWithX | noteheadDoubleWholeWithX |
| triangleUp (`triangle-up`) | noteheadTriangleUpWhole | noteheadTriangleUpHalf | noteheadTriangleUpBlack | noteheadTriangleUpDoubleWhole |
| triangleDown (`triangle-down`) | noteheadTriangleDownWhole | noteheadTriangleDownHalf | noteheadTriangleDownBlack | noteheadTriangleDownDoubleWhole |
| slashed1 (`slashed1`) | noteheadSlashedWhole1 | noteheadSlashedHalf1 | noteheadSlashedBlack1 | noteheadSlashedDoubleWhole1 |
| slashed2 (`slashed2`) | noteheadSlashedWhole2 | noteheadSlashedHalf2 | noteheadSlashedBlack2 | noteheadSlashedDoubleWhole2 |
| diamond (`diamond`) | noteheadDiamondWhole | noteheadDiamondHalf | noteheadDiamondBlack | noteheadDiamondDoubleWhole |
| diamondOld (`diamond-old`) | noteheadDiamondWholeOld | noteheadDiamondHalfOld | noteheadDiamondBlackOld | noteheadDiamondDoubleWholeOld |
| circled (`circled`) | noteheadCircledWhole | noteheadCircledHalf | noteheadCircledBlack | noteheadCircledDoubleWhole |
| circledLarge (`circled-large`) | noteheadCircledWholeLarge | noteheadCircledHalfLarge | noteheadCircledBlackLarge | noteheadCircledDoubleWholeLarge |
| largeArrow (`large-arrow`) | noteheadLargeArrowUpWhole | noteheadLargeArrowUpHalf | noteheadLargeArrowUpBlack | noteheadLargeArrowUpDoubleWhole |
| brevisAlt (`altbrevis`) | noteheadWhole | noteheadHalf | noteheadBlack | noteheadDoubleWholeSquare |
| slash (`slash`) | noteheadSlashWhiteWhole | noteheadSlashWhiteHalf | noteheadSlashHorizontalEnds | noteheadSlashWhiteWhole |
| largeDiamond (`large-diamond`) | noteheadSlashDiamondWhite | noteheadSlashDiamondWhite | noteheadSlashHorizontalEnds | noteheadSlashWhiteWhole |
| sol (`sol`) | noteShapeRoundWhite | noteShapeRoundWhite | noteShapeRoundBlack | noteShapeRoundDoubleWhole |
| la (`la`) | noteShapeSquareWhite | noteShapeSquareWhite | noteShapeSquareBlack | noteShapeSquareDoubleWhole |
| fa (`fa`) | noteShapeTriangleRightWhite | noteShapeTriangleRightWhite | noteShapeTriangleRightBlack | noteShapeTriangleRightDoubleWhole |
| mi (`mi`) | noteShapeDiamondWhite | noteShapeDiamondWhite | noteShapeDiamondBlack | noteShapeDiamondDoubleWhole |
| doShape (`do`) | noteShapeTriangleUpWhite | noteShapeTriangleUpWhite | noteShapeTriangleUpBlack | noteShapeTriangleUpDoubleWhole |
| reShape (`re`) | noteShapeMoonWhite | noteShapeMoonWhite | noteShapeMoonBlack | noteShapeMoonDoubleWhole |
| tiShape (`ti`) | noteShapeTriangleRoundWhite | noteShapeTriangleRoundWhite | noteShapeTriangleRoundBlack | noteShapeTriangleRoundDoubleWhole |
| heavyCross (`heavy-cross`) | noteheadHeavyX | noteheadHeavyX | noteheadHeavyX | noteheadHeavyX |
| heavyCrossHat (`heavy-cross-hat`) | noteheadHeavyXHat | noteheadHeavyXHat | noteheadHeavyXHat | noteheadHeavyXHat |
| doWalker (`do-walker`) | noteShapeKeystoneWhite | … | noteShapeKeystoneBlack | noteShapeKeystoneDoubleWhole |
| reWalker (`re-walker`) | noteShapeQuarterMoonWhite | … | noteShapeQuarterMoonBlack | noteShapeQuarterMoonDoubleWhole |
| tiWalker (`ti-walker`) | noteShapeIsoscelesTriangleWhite | … | noteShapeIsoscelesTriangleBlack | noteShapeIsoscelesTriangleDoubleWhole |
| doFunk (`do-funk`) | noteShapeMoonLeftWhite | … | noteShapeMoonLeftBlack | noteShapeMoonLeftDoubleWhole |
| reFunk (`re-funk`) | noteShapeArrowheadLeftWhite | … | noteShapeArrowheadLeftBlack | noteShapeArrowheadLeftDoubleWhole |
| tiFunk (`ti-funk`) | noteShapeTriangleRoundLeftWhite | … | noteShapeTriangleRoundLeftBlack | noteShapeTriangleRoundLeftDoubleWhole |
| swissRudimentsFlam (`swiss-rudiments-flam`) | noSym | swissRudimentsNoteheadHalfFlam | swissRudimentsNoteheadBlackFlam | noSym |
| swissRudimentsDouble (`swiss-rudiments-double`) | noSym | swissRudimentsNoteheadHalfDouble | swissRudimentsNoteheadBlackDouble | noSym |

(For the `…`-half cells of Walker/Funk rows the white glyph repeats, same as the whole column — confirm at note.cpp:155-159, 177-182.)

**Named-solfège rows** (`note.cpp:160-176`), tokens `<x>-name`, brevis = noSym,
SymId = `note<Syllable>{Whole,Half,Black}` where `<Syllable>` ∈ {Do, Di, Ra,
Re, Ri, Me, Mi, Fa, Fi, Se, **So** (not Sol), Le, La, Li, Te, Ti, Si}. Swift
cases `doName … siName`, tokens `do-name … si-name`.

**Named-pitch rows** (`note.cpp:178-200`), tokens `<x>-name` /
`<x>-sharp-name` / `<x>-flat-name`, brevis = noSym, SymId =
`note<Pitch>[Sharp|Flat]{Whole,Half,Black}` for Pitch ∈ {A,B,C,D,E,F,G} each
with `(none|Sharp|Flat)`, plus `H` (`h-name` → noteH*) and `HSharp`
(`h-sharp-name` → noteHSharp*). Swift cases `aSharpName, aName, aFlatName, …,
hName, hSharpName`.

**Up-stem `noteHeads[1]` overrides** (`note.cpp:205-321`) — identical except:
- `largeArrow` → `noteheadLargeArrowDown{Whole,Half,Black,DoubleWhole}`
- `slash` doubleWhole → `noteheadSlashWhiteDoubleWhole`
- `largeDiamond` doubleWhole → `noteheadSlashWhiteDoubleWhole`
- `fa` → `noteShapeTriangleLeftWhite ×2 / noteShapeTriangleLeftBlack / …DoubleWhole`

### A.2 / A.6 Unique SymId-name lists for the generator

Deduplicate every SymId name in A.1 (drop `noSym`) → `noteheadNames`.
Deduplicate every subtype name in A.5 → `accidentalNames`. Run the generator;
if it prints `MISSING in subset: [...]`, widen the `keep()` ranges in Task 0.1.

### A.4 MS2 `<head>` integer → MS4 token (`decodeHeadType`)

`{0:normal, 1:cross, 2:diamond, 3:triangle-up, 4:mi, 5:slash, 6:xcircle,
7:do, 8:re, 9:fa, 10:la, 11:ti, 12:sol, 13:altbrevis}`. Integers outside 0–13,
MS3 strings not in the A.3 token set, and anything else (except `custom`) →
`mscxDecoderWarn("mscx.note.unsupportedHeadType")` + return nil.

### A.5 AccidentalType — `accidental.{h:35-212, cpp:51-224}`

`Accidental` Swift case ← SMuFL SymId-name (`<subtype>` string) ← semitone
offset. Keep existing cases `sharp/flat/natural/doubleSharp/doubleFlat`.
**Standard (explicit offsets):**
`flat`=accidentalFlat/−1, `natural`=accidentalNatural/0,
`sharp`=accidentalSharp/+1, `doubleSharp`=accidentalDoubleSharp/+2,
`doubleFlat`=accidentalDoubleFlat/−2, `tripleSharp`=accidentalTripleSharp/+3,
`tripleFlat`=accidentalTripleFlat/−3, `naturalFlat`=accidentalNaturalFlat/−1,
`naturalSharp`=accidentalNaturalSharp/+1, `sharpSharp`=accidentalSharpSharp/+2.

**Microtonal families** (each `AccidentalType` → `ACC_LIST[].sym`; **offset =
integer part of MuseScore's `pitchOffset`**: ±¼-tone & purely-cents → 0,
¾-tone → ±1, 5/4-tone → ±2 — read the cited line if unsure):
- *Gould arrow* (cpp:65-76): `flatArrowUp`=accidentalQuarterToneFlatArrowUp,
  `flatArrowDown`=accidentalThreeQuarterTonesFlatArrowDown,
  `naturalArrowUp`=accidentalQuarterToneSharpNaturalArrowUp,
  `naturalArrowDown`=accidentalQuarterToneFlatNaturalArrowDown,
  `sharpArrowUp`=accidentalThreeQuarterTonesSharpArrowUp,
  `sharpArrowDown`=accidentalQuarterToneSharpArrowDown,
  `sharp2ArrowUp`=accidentalFiveQuarterTonesSharpArrowUp,
  `sharp2ArrowDown`=accidentalThreeQuarterTonesSharpArrowDown,
  `flat2ArrowUp`=accidentalThreeQuarterTonesFlatArrowUp,
  `flat2ArrowDown`=accidentalFiveQuarterTonesFlatArrowDown,
  `arrowDown`=accidentalArrowDown, `arrowUp`=accidentalArrowUp.
- *Stein-Zimmermann* (cpp:79-82): `mirroredFlat`=accidentalQuarterToneFlatStein,
  `mirroredFlat2`=accidentalThreeQuarterTonesFlatZimmermann,
  `sharpSlash`=accidentalQuarterToneSharpStein,
  `sharpSlash4`=accidentalThreeQuarterTonesSharpStein.
- *AEU* (cpp:85-88): `flatSlash2`=accidentalBuyukMucennebFlat,
  `flatSlash`=accidentalBakiyeFlat, `sharpSlash3`=accidentalKucukMucennebSharp,
  `sharpSlash2`=accidentalBuyukMucennebSharp.
- *Extended Helmholtz-Ellis* (cpp:91-134), *equal-tempered* (cpp:136-142),
  *HE schisma/comma* (cpp:144-156), *Persian* `sori`=accidentalSori /
  `koron`=accidentalKoron (cpp:159-160), *Wyschnegradsky 12ths* (cpp:163-184),
  *Sagittal* (cpp:187-212), *Turkish folk* (cpp:215-223): transcribe each
  `AccidentalType` → `ACC_LIST[].sym` SymId-name from the cited lines (the
  full list was enumerated in the design survey). All offsets 0 unless the
  name implies a ¾-/5/4-tone. `FOUR_COMMA_SHARP` is commented out — skip it.

`<subtype>` string IS the SymId-name. Parentheses/brackets are the **separate**
`AccidentalBracket` int field `<bracket>` (0=none, 1=parenthesis, 2=bracket;
3=brace deprecated → treat as none). Combined-paren single glyphs
(`accidental*Parens`) are a MuseScore optimization — **out of scope**; always
render enclosure as `left + accidental + right` using `accidentalParensLeft/
Right` / `accidentalBracketLeft/Right`.
