# Parenthesized Noteheads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a note's notehead wrapped in round parentheses `(♪)` end-to-end — import from MSCX (3 representations) and MusicXML, round-trip on MSCX export, and draw in all three renderers.

**Architecture:** Mirror the existing accidental-bracket enclosure feature exactly. A new `NoteParentheses` value lives on `Note`, is carried onto `LayoutChordNote`, and is turned into the already-defined `noteheadParenthesisLeft/Right` SMuFL glyphs (0xE0F5/0xE0F6) by a shared glyph helper + placement helper that all three render paths consume.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing (`@Test`/`#expect`), Foundation `XMLParser` wrapper (`XMLTreeParser`/`XMLTreeNode`), CoreText (Apple metrics), CALayer + SwiftUI Canvas renderers, Android JNI DrawCommand bridge.

## Global Constraints

- **Branch:** `feature/parenthesized-noteheads` (already created; spec committed at `9aab901`).
- **Naming:** idiomatic Swift; original MuseScore C++ names go in `/// C++:` doc comments only.
- **Value types, `Sendable`.** All Score types are `struct`/`enum`. `Note` is `Equatable`, so every stored member must be `Equatable`.
- **Permissive parser, three-way policy:** notehead parentheses are **cosmetic** — unknown/garbled/absent values default to `.none` silently (no `throw`, no diagnostic).
- **English** for all comments / commit messages / identifiers.
- **SwiftLint:** file length ≤ 300 lines; 0 warnings (`swiftlint --quiet Sources Tests`).
- **Android test gating:** any new test file importing an Apple framework or `@testable`-importing an Apple-only sub-library (`SheetMusicLayout`, `SheetMusicUI`, `SheetMusicAudio`, `SheetMusicPDF`, `SheetMusicAndroidJNI`) must be wrapped in `#if !os(Android)` … `#endif`. Run `Scripts/gate-android-tests.sh` after adding test files.
- **Merge gate:** `swift test` 100% green + `Scripts/preflight.sh --apple` + swiftlint 0 warnings.
- **SMuFL glyphs already defined** (do not redefine): `SMuFLCodepoint.noteheadParenthesisLeft = 0xE0F5`, `SMuFLCodepoint.noteheadParenthesisRight = 0xE0F6` (`Sources/SheetMusicLayout/Engraving/SMuFLCodepoints+Noteheads.swift:179-180`).
- **MuseScore representations** (decode all three; see spec for full XML):
  - rep1 (≤4.5): `<Note><Symbol><name>noteheadParenthesisLeft</name></Symbol>…</Note>`
  - rep2 (4.6 — the real `ロビンソン.mscz` fixture): `<Note><parentheses>both</parentheses><Parenthesis>…</Parenthesis>…</Note>`
  - rep3 (4.7+): `<Chord>…<NoteParenGroup><Parenthesis>…</Parenthesis><Notes><NoteIdx>0</NoteIdx></Notes></NoteParenGroup></Chord>`
- **MSCX encoder targets two versions** (`MSCXEncoderOptions.targetVersion`, default `.v4`): `.v3`/`.v2` → MuseScore 3.02 (write rep1), `.v4` → MuseScore 4.60 (write rep2).

---

### Task 1: `NoteParentheses` model + `Note.parentheses` field

**Files:**
- Create: `Sources/SheetMusicCore/Score/NoteParentheses.swift`
- Modify: `Sources/SheetMusicCore/Score/Note.swift` (add field + init param)
- Test: `Tests/SheetMusicTests/NoteParenthesesModelTests.swift`

**Interfaces:**
- Produces:
  - `public enum NoteParentheses: Sendable, Equatable { case none, left, right, both }`
  - `init(mscxToken: String)` — maps `"left"/"right"/"both"` to the case, anything else → `.none`.
  - `var mscxToken: String` — inverse (`.none` → `"none"`).
  - `var hasLeft: Bool` / `var hasRight: Bool`.
  - `Note.parentheses: NoteParentheses` stored property (default `.none`); init param `parentheses: NoteParentheses = .none`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/NoteParenthesesModelTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
import Testing

struct NoteParenthesesModelTests {
    @Test func tokenRoundTripForAllCases() {
        #expect(NoteParentheses(mscxToken: "none") == .none)
        #expect(NoteParentheses(mscxToken: "left") == .left)
        #expect(NoteParentheses(mscxToken: "right") == .right)
        #expect(NoteParentheses(mscxToken: "both") == .both)
        #expect(NoteParentheses(mscxToken: "garbage") == .none)
        #expect(NoteParentheses.none.mscxToken == "none")
        #expect(NoteParentheses.left.mscxToken == "left")
        #expect(NoteParentheses.right.mscxToken == "right")
        #expect(NoteParentheses.both.mscxToken == "both")
    }

    @Test func hasLeftHasRight() {
        #expect(NoteParentheses.both.hasLeft && NoteParentheses.both.hasRight)
        #expect(NoteParentheses.left.hasLeft && !NoteParentheses.left.hasRight)
        #expect(!NoteParentheses.right.hasLeft && NoteParentheses.right.hasRight)
        #expect(!NoteParentheses.none.hasLeft && !NoteParentheses.none.hasRight)
    }

    @Test func noteDefaultsToNoneAndCarriesValue() {
        #expect(Note(pitch: 60, tpc: 14).parentheses == .none)
        #expect(Note(pitch: 60, tpc: 14, parentheses: .both).parentheses == .both)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NoteParenthesesModelTests`
Expected: FAIL — `cannot find 'NoteParentheses' in scope` (and `Note` has no `parentheses` argument).

- [ ] **Step 3: Create the enum**

Create `Sources/SheetMusicCore/Score/NoteParentheses.swift`:

```swift
/// Round-parenthesis enclosure drawn around a notehead, used by MuseScore
/// for editorial / cautionary / "ghost" notes. Orthogonal to the notehead
/// shape (`Note.headType`); only round parentheses exist for noteheads
/// (square brackets are an accidental-only feature).
///
/// C++: `mu::engraving::ParenthesesMode` (`src/engraving/types/types.h`).
/// MuseScore only ever sets `both` or `none` for notes, but the full
/// directional set is modeled so a single side round-trips if encountered.
public enum NoteParentheses: Sendable, Equatable {
    case none
    case left
    case right
    case both

    /// Decode from a MuseScore `<parentheses>` text token
    /// (`none` / `left` / `right` / `both`). Unknown tokens → `.none`.
    public init(mscxToken: String) {
        switch mscxToken {
        case "left": self = .left
        case "right": self = .right
        case "both": self = .both
        default: self = .none
        }
    }

    /// MuseScore `<parentheses>` text token.
    public var mscxToken: String {
        switch self {
        case .none: "none"
        case .left: "left"
        case .right: "right"
        case .both: "both"
        }
    }

    /// True when a left parenthesis should be drawn.
    public var hasLeft: Bool { self == .left || self == .both }
    /// True when a right parenthesis should be drawn.
    public var hasRight: Bool { self == .right || self == .both }
}
```

- [ ] **Step 4: Add the field to `Note`**

In `Sources/SheetMusicCore/Score/Note.swift`, add the stored property after `headType` (line 31):

```swift
    /// Round parentheses drawn around this notehead. MuseScore stores
    /// `<parentheses>both</parentheses>` on the note (4.6), a `<Symbol>`
    /// pair (≤4.5), or a chord-level `<NoteParenGroup>` (4.7+). Absent
    /// means `.none`. Display-only; MIDI is unaffected.
    public var parentheses: NoteParentheses
```

Add the init parameter after `headType: String? = nil,` (line 62):

```swift
        headType: String? = nil,
        parentheses: NoteParentheses = .none,
        isSmall: Bool = false,
```

And the assignment after `self.headType = headType` (line 75):

```swift
        self.headType = headType
        self.parentheses = parentheses
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter NoteParenthesesModelTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/Score/NoteParentheses.swift Sources/SheetMusicCore/Score/Note.swift Tests/SheetMusicTests/NoteParenthesesModelTests.swift
git commit -m "feat(core): NoteParentheses model + Note.parentheses field"
```

---

### Task 2: MSCX Note-level import (rep1 + rep2)

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Note.swift` (add `decodeParentheses` helper; set `parentheses` in `decode`)
- Test: `Tests/SheetMusicTests/NoteParenthesesMSCXDecodeTests.swift`

**Interfaces:**
- Consumes: `Note.parentheses` (Task 1), `XMLTreeNode` (`.first`/`.all`/`.text`/`.children`/`.name`).
- Produces: `Note.decode(_:)` now populates `parentheses` from rep1 (`<Symbol>`) and rep2 (`<parentheses>` / `<Parenthesis>`).

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/NoteParenthesesMSCXDecodeTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct NoteParenthesesMSCXDecodeTests {
    private func parseNote(_ xml: String) throws -> Note {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Note.decode(node)
    }

    // rep2 (MuseScore 4.6) — the real ロビンソン.mscz form.
    @Test func rep2BothFromParenthesesProperty() throws {
        let xml = """
        <Note><parentheses>both</parentheses>\
        <Parenthesis><track>16</track></Parenthesis>\
        <Parenthesis><horizontalDirection>right</horizontalDirection><track>16</track></Parenthesis>\
        <pitch>45</pitch><tpc>17</tpc></Note>
        """
        #expect(try parseNote(xml).parentheses == .both)
    }

    @Test func rep2LeftAndRightTokens() throws {
        let left = "<Note><parentheses>left</parentheses><pitch>60</pitch><tpc>14</tpc></Note>"
        let right = "<Note><parentheses>right</parentheses><pitch>60</pitch><tpc>14</tpc></Note>"
        #expect(try parseNote(left).parentheses == .left)
        #expect(try parseNote(right).parentheses == .right)
    }

    // rep1 (MuseScore ≤4.5) — <Symbol><name>… form.
    @Test func rep1BothFromSymbols() throws {
        let xml = """
        <Note>\
        <Symbol><name>noteheadParenthesisLeft</name></Symbol>\
        <Symbol><name>noteheadParenthesisRight</name></Symbol>\
        <pitch>60</pitch><tpc>14</tpc></Note>
        """
        #expect(try parseNote(xml).parentheses == .both)
    }

    @Test func rep1LeftOnlyFromSymbol() throws {
        let xml = """
        <Note><Symbol><name>noteheadParenthesisLeft</name></Symbol>\
        <pitch>60</pitch><tpc>14</tpc></Note>
        """
        #expect(try parseNote(xml).parentheses == .left)
    }

    @Test func absentDefaultsToNone() throws {
        #expect(try parseNote("<Note><pitch>60</pitch><tpc>14</tpc></Note>").parentheses == .none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NoteParenthesesMSCXDecodeTests`
Expected: FAIL — every `#expect` returns `.none` (decoder doesn't read parentheses yet).

- [ ] **Step 3: Implement `decodeParentheses` and wire it into `decode`**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Note.swift`, inside `Note.decode(_:)`, add after the `play` line (line 51) and pass into the initializer:

```swift
        let play = node.first("play")?.text != "0"
        let parentheses = decodeParentheses(node)
        var note = Note(
            pitch: pitch,
            tpc: tpc,
            accidental: accidental,
            accidentalBracket: accidentalBracket,
            accidentalRole: accidentalRole,
            tieForward: tieForward,
            tieBack: tieBack,
            glissando: glissando,
            headType: headType,
            parentheses: parentheses,
            isSmall: isSmall,
            play: play,
        )
```

Add this helper method to the `extension Note` (e.g. after `decodeAccidentalNode`):

```swift
    /// Decode a notehead parenthesis from a `<Note>` element across the two
    /// note-level MuseScore representations. Chord-level rep3
    /// (`<NoteParenGroup>`) is handled in `Chord.decode`.
    ///
    /// * rep2 (4.6): `<parentheses>both</parentheses>` text token.
    /// * rep1 (≤4.5): `<Symbol><name>noteheadParenthesisLeft/Right</name></Symbol>`.
    ///
    /// Cosmetic: unknown / absent → `.none` (no throw, no diagnostic).
    private static func decodeParentheses(_ node: XMLTreeNode) -> NoteParentheses {
        // rep2: explicit <parentheses> token wins.
        if let token = node.first("parentheses")?.text {
            return NoteParentheses(mscxToken: token)
        }
        // rep1: SMuFL parenthesis symbols attached to the note.
        var left = false
        var right = false
        for symbol in node.all("Symbol") {
            switch symbol.first("name")?.text {
            case "noteheadParenthesisLeft": left = true
            case "noteheadParenthesisRight": right = true
            default: continue
            }
        }
        if left, right { return .both }
        if left { return .left }
        if right { return .right }
        // Defensive: 4.6 generic <Parenthesis> children without the
        // <parentheses> property still mean the note is parenthesized.
        if node.children.contains(where: { $0.name == "Parenthesis" }) { return .both }
        return .none
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NoteParenthesesMSCXDecodeTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Note.swift Tests/SheetMusicTests/NoteParenthesesMSCXDecodeTests.swift
git commit -m "feat(mscx): decode notehead parentheses (rep1 Symbol + rep2 property)"
```

---

### Task 3: MSCX Chord-level import (rep3 `<NoteParenGroup>`)

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift` (apply `<NoteParenGroup>` after decoding notes)
- Test: `Tests/SheetMusicTests/NoteParenthesesChordDecodeTests.swift`

**Interfaces:**
- Consumes: `Note.parentheses` (Task 1), `Chord.decode(_:)`.
- Produces: `Chord.decode(_:)` sets `parentheses = .both` on each note referenced by a `<NoteParenGroup>`.

**Note for implementer:** MuseScore synthesizes both sides on read of a `<NoteParenGroup>` (missing `<Parenthesis>` children are filled in), so a group always means **both** for the notes it lists. We do not model rep3 single-sided parens (documented spec non-goal).

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/NoteParenthesesChordDecodeTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct NoteParenthesesChordDecodeTests {
    private func parseChord(_ xml: String) throws -> Chord {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Chord.decode(node)
    }

    @Test func rep3GroupParenthesizesReferencedNotes() throws {
        let xml = """
        <Chord><durationType>quarter</durationType>\
        <Note><pitch>60</pitch><tpc>14</tpc></Note>\
        <Note><pitch>64</pitch><tpc>18</tpc></Note>\
        <NoteParenGroup>\
        <Parenthesis><horizontalDirection>left</horizontalDirection></Parenthesis>\
        <Parenthesis><horizontalDirection>right</horizontalDirection></Parenthesis>\
        <Notes><NoteIdx>0</NoteIdx><NoteIdx>1</NoteIdx></Notes>\
        </NoteParenGroup></Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.notes[0].parentheses == .both)
        #expect(chord.notes[1].parentheses == .both)
    }

    @Test func rep3GroupWithoutParenthesisChildrenStillBoth() throws {
        // MuseScore omits <Parenthesis> children when unmodified.
        let xml = """
        <Chord><durationType>quarter</durationType>\
        <Note><pitch>60</pitch><tpc>14</tpc></Note>\
        <Note><pitch>64</pitch><tpc>18</tpc></Note>\
        <NoteParenGroup><Notes><NoteIdx>1</NoteIdx></Notes></NoteParenGroup></Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.notes[0].parentheses == .none)
        #expect(chord.notes[1].parentheses == .both)
    }

    @Test func rep3OutOfRangeIndexIgnored() throws {
        let xml = """
        <Chord><durationType>quarter</durationType>\
        <Note><pitch>60</pitch><tpc>14</tpc></Note>\
        <NoteParenGroup><Notes><NoteIdx>5</NoteIdx></Notes></NoteParenGroup></Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.notes[0].parentheses == .none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NoteParenthesesChordDecodeTests`
Expected: FAIL — all notes report `.none`.

- [ ] **Step 3: Implement**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`, change the notes line in `Chord.decode` (line 15) from `let notes` to `var notes` and apply the group:

```swift
        let dots = Int(node.first("dots")?.text ?? "0") ?? 0
        let duration = baseDuration.dotted(dots)
        var notes = try decodeNotes(node)
        applyNoteParenGroup(node, to: &notes)
```

Add this helper to `extension Chord` (e.g. after `decodeNotes`):

```swift
    /// Apply a MuseScore 4.7+ chord-level `<NoteParenGroup>` to the chord's
    /// decoded notes. The group binds parentheses to notes by 0-based
    /// `<NoteIdx>` into the chord's note list. MuseScore synthesizes both
    /// sides on read, so a referenced note is always `.both`. Out-of-range
    /// indices are skipped (permissive parser).
    private static func applyNoteParenGroup(_ node: XMLTreeNode, to notes: inout [Note]) {
        guard let group = node.first("NoteParenGroup"),
              let notesNode = group.first("Notes")
        else { return }
        for idxNode in notesNode.all("NoteIdx") {
            guard let idx = Int(idxNode.text ?? ""), notes.indices.contains(idx) else { continue }
            notes[idx].parentheses = .both
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NoteParenthesesChordDecodeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift Tests/SheetMusicTests/NoteParenthesesChordDecodeTests.swift
git commit -m "feat(mscx): decode chord-level NoteParenGroup (rep3) notehead parentheses"
```

---

### Task 4: MusicXML import (`<notehead parentheses="yes">`)

**Files:**
- Modify: `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift`
- Test: `Tests/SheetMusicTests/NoteParenthesesMusicXMLTests.swift`

**Interfaces:**
- Consumes: `Note.parentheses` (Task 1), `MusicXMLParser.parse(_:)`.
- Produces: a `<note>` with `<notehead parentheses="yes">` decodes to `Note.parentheses == .both`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/NoteParenthesesMusicXMLTests.swift`:

```swift
import Foundation
import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

struct NoteParenthesesMusicXMLTests {
    private func firstNoteParens(noteheadXML: String) throws -> NoteParentheses {
        let xml = Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>X</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <key><fifths>0</fifths></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>G</sign><line>2</line></clef>
              </attributes>
              <note>
                <pitch><step>C</step><octave>5</octave></pitch>
                <duration>4</duration><voice>1</voice><type>whole</type>
                \(noteheadXML)
              </note>
            </measure>
          </part>
        </score-partwise>
        """.utf8)
        let score = try MusicXMLParser.parse(xml)
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        for element in elements {
            if case let .chord(chord) = element { return chord.notes[0].parentheses }
        }
        return .none
    }

    @Test func parenthesesYesDecodesToBoth() throws {
        #expect(try firstNoteParens(noteheadXML: "<notehead parentheses=\"yes\">normal</notehead>") == .both)
    }

    @Test func noNoteheadDefaultsToNone() throws {
        #expect(try firstNoteParens(noteheadXML: "") == .none)
    }

    @Test func noteheadWithoutParenthesesDefaultsToNone() throws {
        #expect(try firstNoteParens(noteheadXML: "<notehead>normal</notehead>") == .none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NoteParenthesesMusicXMLTests`
Expected: FAIL — `parenthesesYesDecodesToBoth` returns `.none`.

- [ ] **Step 3: Implement**

In `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift`, in `decodeNote`, add before the `let note = Note(...)` construction (line 79) and pass the value in:

```swift
        let accidental = decodeAccidental(node)
        let (tieForward, tieBack) = decodeTies(node)
        let parentheses = decodeNoteheadParentheses(node)
        let note = Note(
            pitch: midi,
            tpc: tpc,
            accidental: accidental,
            tieForward: tieForward,
            tieBack: tieBack,
            parentheses: parentheses,
        )
```

Add this helper to `enum MusicXMLNoteDecoder` (e.g. after `decodeAccidental`):

```swift
    /// MusicXML wraps a notehead in parentheses via `<notehead parentheses="yes">`.
    /// We only model the both-sides case (MusicXML has no per-side notehead
    /// parenthesis). Absent element or `parentheses != "yes"` → `.none`.
    private static func decodeNoteheadParentheses(_ node: XMLTreeNode) -> NoteParentheses {
        guard let notehead = node.first("notehead") else { return .none }
        return notehead.attributes["parentheses"] == "yes" ? .both : .none
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NoteParenthesesMusicXMLTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Note.swift Tests/SheetMusicTests/NoteParenthesesMusicXMLTests.swift
git commit -m "feat(musicxml): decode <notehead parentheses=\"yes\">"
```

---

### Task 5: MSCX export round-trip (rep2 for v4, rep1 for v3)

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift`
- Test: `Tests/SheetMusicTests/NoteParenthesesRoundTripTests.swift`

**Interfaces:**
- Consumes: `Note.parentheses`, `Note.encode(options:)`, `Note.decode(_:)`, `MSCXEncoderOptions(targetVersion:)`, `MSCXVersion` (`.v2`/`.v3`/`.v4`).
- Produces: `Note.encode` emits notehead parentheses in the version-appropriate representation; decode→encode→decode preserves the mode.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/NoteParenthesesRoundTripTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct NoteParenthesesRoundTripTests {
    private func roundTrip(_ parens: NoteParentheses, version: MSCXVersion) throws -> NoteParentheses {
        let note = Note(pitch: 60, tpc: 14, parentheses: parens)
        let encoded = note.encode(options: MSCXEncoderOptions(targetVersion: version))
        return try Note.decode(encoded).parentheses
    }

    @Test func v4RoundTripsAllModes() throws {
        #expect(try roundTrip(.both, version: .v4) == .both)
        #expect(try roundTrip(.left, version: .v4) == .left)
        #expect(try roundTrip(.right, version: .v4) == .right)
        #expect(try roundTrip(.none, version: .v4) == .none)
    }

    @Test func v3RoundTripsViaSymbols() throws {
        #expect(try roundTrip(.both, version: .v3) == .both)
        #expect(try roundTrip(.left, version: .v3) == .left)
        #expect(try roundTrip(.right, version: .v3) == .right)
        #expect(try roundTrip(.none, version: .v3) == .none)
    }

    @Test func v4EmitsParenthesesElement() throws {
        let note = Note(pitch: 60, tpc: 14, parentheses: .both)
        let encoded = note.encode(options: MSCXEncoderOptions(targetVersion: .v4))
        #expect(encoded.first("parentheses")?.text == "both")
    }

    @Test func v3EmitsSymbolElements() throws {
        let note = Note(pitch: 60, tpc: 14, parentheses: .both)
        let encoded = note.encode(options: MSCXEncoderOptions(targetVersion: .v3))
        let symNames = encoded.all("Symbol").compactMap { $0.first("name")?.text }
        #expect(symNames.contains("noteheadParenthesisLeft"))
        #expect(symNames.contains("noteheadParenthesisRight"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NoteParenthesesRoundTripTests`
Expected: FAIL — encoder writes nothing; decode returns `.none` and the element-presence checks fail.

- [ ] **Step 3: Implement**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift`, inside `func encode(...)`, add a parentheses block immediately **before** the `<pitch>` append (line 71):

```swift
        appendParentheses(into: &children, targetVersion: options.targetVersion)
        children.append(XMLTreeNode(name: "pitch", text: String(pitch)))
        children.append(XMLTreeNode(name: "tpc", text: String(tpc)))
```

Add this private helper to `extension Note` (e.g. after `glissandoSpanner`):

```swift
    /// Append notehead-parenthesis elements in the representation matching
    /// the target MuseScore version: rep2 (`<parentheses>` + `<Parenthesis>`)
    /// for `.v4`, rep1 (`<Symbol><name>…</name></Symbol>`) for `.v2`/`.v3`.
    private func appendParentheses(
        into children: inout [XMLTreeNode],
        targetVersion: MSCXVersion,
    ) {
        guard parentheses != .none else { return }
        switch targetVersion {
        case .v4:
            children.append(XMLTreeNode(name: "parentheses", text: parentheses.mscxToken))
            if parentheses.hasLeft {
                children.append(XMLTreeNode(name: "Parenthesis", children: []))
            }
            if parentheses.hasRight {
                children.append(XMLTreeNode(name: "Parenthesis", children: [
                    XMLTreeNode(name: "horizontalDirection", text: "right"),
                ]))
            }
        case .v2, .v3:
            if parentheses.hasLeft {
                children.append(XMLTreeNode(name: "Symbol", children: [
                    XMLTreeNode(name: "name", text: "noteheadParenthesisLeft"),
                ]))
            }
            if parentheses.hasRight {
                children.append(XMLTreeNode(name: "Symbol", children: [
                    XMLTreeNode(name: "name", text: "noteheadParenthesisRight"),
                ]))
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NoteParenthesesRoundTripTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift Tests/SheetMusicTests/NoteParenthesesRoundTripTests.swift
git commit -m "feat(mscx): export notehead parentheses (rep2 for v4, rep1 for v3)"
```

---

### Task 6: Glyph selection + placement helpers

**Files:**
- Create: `Sources/SheetMusicLayout/Engraving/NoteheadParenthesisGlyph.swift`
- Create: `Sources/SheetMusicLayout/Engraving/NoteheadParenthesisPlacement.swift`
- Test: `Tests/SheetMusicTests/NoteheadParenthesisGlyphTests.swift`

**Interfaces:**
- Consumes: `NoteParentheses`, `SMuFLCodepoint.noteheadParenthesisLeft/Right`, `StemGeometry.attachDx(sp:)`.
- Produces:
  - `NoteheadParenthesisGlyph.glyphs(for: NoteParentheses) -> (left: UInt32?, right: UInt32?)`
  - `NoteheadParenthesisPlacement.gapSp: CGFloat`
  - `NoteheadParenthesisPlacement.leftParenCenterX(noteheadCenterX:parenAdvance:sp:) -> CGFloat`
  - `NoteheadParenthesisPlacement.rightParenCenterX(noteheadCenterX:parenAdvance:sp:) -> CGFloat`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/NoteheadParenthesisGlyphTests.swift`:

```swift
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

struct NoteheadParenthesisGlyphTests {
    @Test func glyphsPerMode() {
        let both = NoteheadParenthesisGlyph.glyphs(for: .both)
        #expect(both.left == SMuFLCodepoint.noteheadParenthesisLeft)
        #expect(both.right == SMuFLCodepoint.noteheadParenthesisRight)

        let left = NoteheadParenthesisGlyph.glyphs(for: .left)
        #expect(left.left == SMuFLCodepoint.noteheadParenthesisLeft)
        #expect(left.right == nil)

        let right = NoteheadParenthesisGlyph.glyphs(for: .right)
        #expect(right.left == nil)
        #expect(right.right == SMuFLCodepoint.noteheadParenthesisRight)

        let none = NoteheadParenthesisGlyph.glyphs(for: .none)
        #expect(none.left == nil && none.right == nil)
    }

    @Test func placementBracketsTheNotehead() {
        let sp: CGFloat = 10
        let center: CGFloat = 100
        let adv: CGFloat = 4
        let leftX = NoteheadParenthesisPlacement.leftParenCenterX(
            noteheadCenterX: center, parenAdvance: adv, sp: sp,
        )
        let rightX = NoteheadParenthesisPlacement.rightParenCenterX(
            noteheadCenterX: center, parenAdvance: adv, sp: sp,
        )
        // Left paren center sits left of the notehead center; right paren right of it.
        #expect(leftX < center)
        #expect(rightX > center)
        // Symmetric about the notehead center for equal advances.
        #expect(abs((center - leftX) - (rightX - center)) < 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NoteheadParenthesisGlyphTests`
Expected: FAIL — `cannot find 'NoteheadParenthesisGlyph' / 'NoteheadParenthesisPlacement' in scope`.

- [ ] **Step 3: Create the glyph helper**

Create `Sources/SheetMusicLayout/Engraving/NoteheadParenthesisGlyph.swift`:

```swift
import SheetMusicCore

/// SMuFL codepoints for the round parentheses drawn around a notehead.
/// Single source of truth so the CALayer renderer, the SwiftUI Canvas
/// renderer, and the Android bridge agree. Mirrors `AccidentalGlyph.enclosure`.
public enum NoteheadParenthesisGlyph {
    /// Returns the left/right parenthesis codepoints for `parentheses`.
    /// A side is `nil` when it should not be drawn.
    public static func glyphs(
        for parentheses: NoteParentheses,
    ) -> (left: UInt32?, right: UInt32?) {
        (
            left: parentheses.hasLeft ? SMuFLCodepoint.noteheadParenthesisLeft : nil,
            right: parentheses.hasRight ? SMuFLCodepoint.noteheadParenthesisRight : nil,
        )
    }
}
```

- [ ] **Step 4: Create the placement helper**

Create `Sources/SheetMusicLayout/Engraving/NoteheadParenthesisPlacement.swift`:

```swift
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Shared geometry for placing round parentheses to the left and right of a
/// notehead. Single source of truth consumed by the CALayer renderer, the
/// SwiftUI Canvas renderer, and the Android bridge so all three agree on
/// offsets. Mirrors `AccidentalPlacement`.
public enum NoteheadParenthesisPlacement {
    /// Gap between a parenthesis's inner edge and the notehead's edge,
    /// in staff spaces. Tuned visually against the real fixture.
    public static let gapSp: CGFloat = 0.16

    /// Center x of the LEFT parenthesis (renderers draw center-anchored
    /// glyphs). The parenthesis's right edge sits `gapSp * sp` left of the
    /// notehead's left edge; `StemGeometry.attachDx` is the notehead's
    /// half-advance (Bravura `noteheadBlack` half-width = 0.59 sp).
    public static func leftParenCenterX(
        noteheadCenterX: CGFloat,
        parenAdvance: CGFloat,
        sp: CGFloat,
    ) -> CGFloat {
        noteheadCenterX - StemGeometry.attachDx(sp: sp) - gapSp * sp - parenAdvance / 2
    }

    /// Center x of the RIGHT parenthesis. Its left edge sits `gapSp * sp`
    /// right of the notehead's right edge.
    public static func rightParenCenterX(
        noteheadCenterX: CGFloat,
        parenAdvance: CGFloat,
        sp: CGFloat,
    ) -> CGFloat {
        noteheadCenterX + StemGeometry.attachDx(sp: sp) + gapSp * sp + parenAdvance / 2
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter NoteheadParenthesisGlyphTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Engraving/NoteheadParenthesisGlyph.swift Sources/SheetMusicLayout/Engraving/NoteheadParenthesisPlacement.swift Tests/SheetMusicTests/NoteheadParenthesisGlyphTests.swift
git commit -m "feat(layout): notehead parenthesis glyph + placement helpers"
```

---

### Task 7: Carry `parentheses` onto `LayoutChordNote`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift` (field + init param)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift:661, 2008, 2072`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift:59, 198`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift:307`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Chord.swift:48`

**Interfaces:**
- Consumes: `NoteParentheses`, `Note.parentheses`.
- Produces: `LayoutChordNote.parentheses: NoteParentheses` (default `.none`), populated at every construction site.

**Note for implementer:** this is plumbing with a defaulted field, so it cannot break existing tests. Its end-to-end correctness is proven by Task 10's Android DrawCommand test (which cannot pass unless the value reaches the renderer). The "test" step here is the full suite staying green.

- [ ] **Step 1: Add the field + init param to `LayoutChordNote`**

In `Sources/SheetMusicLayout/Layout/LayoutElement.swift`, add the stored property after `accidentalBracket` (line 322):

```swift
    public let accidentalBracket: AccidentalBracket
    /// Round parentheses drawn around this notehead. `.none` (default) =
    /// none. Carried from `Note.parentheses` and consumed by all three
    /// render paths via `NoteheadParenthesisGlyph.glyphs`.
    public let parentheses: NoteParentheses
```

Add the init param after `accidentalBracket: AccidentalBracket = .none,` (line 336):

```swift
        accidentalBracket: AccidentalBracket = .none,
        parentheses: NoteParentheses = .none,
```

Add the assignment after `self.accidentalBracket = accidentalBracket` (line 349):

```swift
        self.accidentalBracket = accidentalBracket
        self.parentheses = parentheses
```

- [ ] **Step 2: Populate at the two `LayoutEngine+Placement` Note-sourced sites**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`, after each line that reads `accidentalBracket: note.accidentalBracket,` (lines 661 and 2072), add:

```swift
                            accidentalBracket: note.accidentalBracket,
                            parentheses: note.parentheses,
```

(Match the existing indentation at each site.)

- [ ] **Step 3: Populate at the `n.`-sourced Placement site**

In the same file at line 2008, after `accidentalBracket: n.accidentalBracket,` add:

```swift
                accidentalBracket: n.accidentalBracket,
                parentheses: n.parentheses,
```

- [ ] **Step 4: Populate at the two `LayoutEngine+Translate` sites**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift`, after each `accidentalBracket: $0.accidentalBracket,` (lines 59 and 198), add:

```swift
                    accidentalBracket: $0.accidentalBracket,
                    parentheses: $0.parentheses,
```

- [ ] **Step 5: Populate at the two renderer rebuild sites**

In `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift` after line 307 (`accidentalBracket: $0.accidentalBracket,`):

```swift
                    accidentalBracket: $0.accidentalBracket,
                    parentheses: $0.parentheses,
```

In `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Chord.swift` after line 48 (`accidentalBracket: n.accidentalBracket,`):

```swift
                accidentalBracket: n.accidentalBracket,
                parentheses: n.parentheses,
```

- [ ] **Step 6: Build + run the full suite to confirm nothing breaks**

Run: `swift build`
Expected: builds clean (every `LayoutChordNote(...)` site compiles; the new param has a default).

Run: `swift test`
Expected: PASS (all existing tests still green; new param defaults to `.none`).

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutElement.swift Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift Sources/SheetMusicUI/Rendering/ScoreCanvas.swift Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Chord.swift
git commit -m "feat(layout): carry NoteParentheses onto LayoutChordNote"
```

---

### Task 8: Render in CALayer renderer (active path)

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Chord.swift` (add `drawNoteheadParentheses`; call it in `drawChord`)

**Interfaces:**
- Consumes: `LayoutChordNote.parentheses`, `NoteheadParenthesisGlyph.glyphs`, `NoteheadParenthesisPlacement`, `FontMetrics.provider.typographicWidth`, `glyphLayer`.
- Produces: parentheses drawn around the notehead in the CALayer path.

**Verification:** visual (Task 11). No CALayer-introspection unit test — mirrors how the accidental bracket itself was validated.

- [ ] **Step 1: Add the draw helper**

In `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Chord.swift`, add this method to the `extension ScoreLayerBuilder` (e.g. after `drawAccidental`, before `// MARK: - Dots`):

```swift
    // MARK: - Notehead parentheses

    /// Draw round parentheses around a notehead. Glyphs + offsets come from
    /// the shared `NoteheadParenthesisGlyph` / `NoteheadParenthesisPlacement`
    /// so this matches the Canvas and Android paths. Parens inherit the
    /// notehead's font size (so small / cue notes scale automatically) and color.
    private static func drawNoteheadParentheses(
        parentheses: NoteParentheses,
        origin: CGPoint,
        color: CGColor,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        let (leftCp, rightCp) = NoteheadParenthesisGlyph.glyphs(for: parentheses)
        let bravuraFont = LayoutFont(
            face: SMuFLFamily.bravura,
            pointSize: metrics.glyphFontSize,
        )
        if let leftCp, let lSc = UnicodeScalar(leftCp) {
            let adv = FontMetrics.provider.typographicWidth(text: String(lSc), font: bravuraFont)
            let x = NoteheadParenthesisPlacement.leftParenCenterX(
                noteheadCenterX: origin.x, parenAdvance: adv, sp: metrics.sp,
            )
            glyphLayer(
                Character(lSc), at: CGPoint(x: x, y: origin.y),
                size: metrics.glyphFontSize, color: color, height: height,
            ).map { parent.addSublayer($0) }
        }
        if let rightCp, let rSc = UnicodeScalar(rightCp) {
            let adv = FontMetrics.provider.typographicWidth(text: String(rSc), font: bravuraFont)
            let x = NoteheadParenthesisPlacement.rightParenCenterX(
                noteheadCenterX: origin.x, parenAdvance: adv, sp: metrics.sp,
            )
            glyphLayer(
                Character(rSc), at: CGPoint(x: x, y: origin.y),
                size: metrics.glyphFontSize, color: color, height: height,
            ).map { parent.addSublayer($0) }
        }
    }
```

- [ ] **Step 2: Call it in `drawChord`**

In `drawChord`, immediately after the notehead glyph is added (after the `context.attach(layer, to: .note(n.noteID))` block ending at line 121, before the accidental `if let acc = n.accidental` block), insert:

```swift
            drawNoteheadParentheses(
                parentheses: n.parentheses,
                origin: visualOrigin,
                color: headColor,
                metrics: metrics, height: height, into: noteTarget,
            )
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Run the full suite (regression check)**

Run: `swift test`
Expected: PASS (no regressions).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Chord.swift
git commit -m "feat(ui): draw notehead parentheses in CALayer renderer"
```

---

### Task 9: Render in SwiftUI Canvas renderer

**Files:**
- Create: `Sources/SheetMusicUI/Rendering/NoteheadParenthesisRenderer.swift`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift` (call in both the gray + normal note branches)

**Interfaces:**
- Consumes: `LayoutChordNote.parentheses`, `NoteheadParenthesisGlyph`, `NoteheadParenthesisPlacement`, `FontMetrics.provider.typographicWidth`, `GraphicsContext.drawGlyph`.
- Produces: `NoteheadParenthesisRenderer.draw(context:parentheses:origin:color:metrics:)`.

**Verification:** visual (Task 11).

- [ ] **Step 1: Create the renderer**

Create `Sources/SheetMusicUI/Rendering/NoteheadParenthesisRenderer.swift`:

```swift
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum NoteheadParenthesisRenderer {
    /// Draw round parentheses around a notehead in the SwiftUI Canvas path.
    /// Shares `NoteheadParenthesisGlyph` / `NoteheadParenthesisPlacement` with
    /// the CALayer and Android paths so the three renderers can't disagree.
    ///
    /// - Parameters:
    ///   - origin: Center of the notehead in canvas coordinates.
    ///   - color: Notehead color (parens match the head).
    static func draw(
        context: inout GraphicsContext,
        parentheses: NoteParentheses,
        origin: CGPoint,
        color: Color = .primary,
        metrics: StaffMetrics,
    ) {
        let (leftCp, rightCp) = NoteheadParenthesisGlyph.glyphs(for: parentheses)
        let bravuraFont = LayoutFont(
            face: SMuFLFamily.bravura,
            pointSize: metrics.glyphFontSize,
        )
        if let leftCp, let lSc = UnicodeScalar(leftCp) {
            let adv = FontMetrics.provider.typographicWidth(text: String(lSc), font: bravuraFont)
            let x = NoteheadParenthesisPlacement.leftParenCenterX(
                noteheadCenterX: origin.x, parenAdvance: adv, sp: metrics.sp,
            )
            context.drawGlyph(
                Character(lSc), at: CGPoint(x: x, y: origin.y),
                size: metrics.glyphFontSize, color: color,
            )
        }
        if let rightCp, let rSc = UnicodeScalar(rightCp) {
            let adv = FontMetrics.provider.typographicWidth(text: String(rSc), font: bravuraFont)
            let x = NoteheadParenthesisPlacement.rightParenCenterX(
                noteheadCenterX: origin.x, parenAdvance: adv, sp: metrics.sp,
            )
            context.drawGlyph(
                Character(rSc), at: CGPoint(x: x, y: origin.y),
                size: metrics.glyphFontSize, color: color,
            )
        }
    }
}
```

**Implementer note:** verify the `GraphicsContext.drawGlyph` signature in `Sources/SheetMusicUI/Rendering/GraphicsContext+Glyph.swift` — it is `drawGlyph(_:at:size:color:anchor:)` with `color` defaulted. The call above passes `color:` positionally-by-label; confirm the label order matches (`AccidentalRenderer` omits `color`, drawing in the ambient color — if passing `color:` causes an overload issue, drop it and rely on the ambient context color set by the caller, exactly as `AccidentalRenderer.draw` does).

- [ ] **Step 2: Call it in both note branches of `ScoreCanvas`**

In `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift`, in the chord `for n in shiftedNotes` loop:

In the **invisible/gray** branch, after `NoteheadRenderer.drawHead(context: &gray, …)` (the call ending at line 359) and before the `if let acc = n.accidental` block (line 360):

```swift
                    NoteheadParenthesisRenderer.draw(
                        context: &gray, parentheses: n.parentheses,
                        origin: visualOrigin, metrics: chordMetrics,
                    )
```

In the **visible** branch, after `NoteheadRenderer.drawHead(context: &context, …)` (the call ending at line 383) and before the `if let acc = n.accidental` block (line 384):

```swift
                    NoteheadParenthesisRenderer.draw(
                        context: &context, parentheses: n.parentheses,
                        origin: visualOrigin, color: headColor,
                        metrics: chordMetrics,
                    )
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Run the full suite (regression check)**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/NoteheadParenthesisRenderer.swift Sources/SheetMusicUI/Rendering/ScoreCanvas.swift
git commit -m "feat(ui): draw notehead parentheses in SwiftUI Canvas renderer"
```

---

### Task 10: Render in Android bridge + end-to-end DrawCommand test

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/LayoutBridge+Chord.swift` (emit parens in `emitNoteGlyphs`)
- Test: `Tests/SheetMusicTests/AndroidJNI/LayoutBridgeNoteParenthesesTests.swift`

**Interfaces:**
- Consumes: `LayoutChordNote.parentheses`, `NoteheadParenthesisGlyph`, `NoteheadParenthesisPlacement`, `FontMetrics.provider.typographicWidth`, `emitCenterAnchoredGlyph`, `ptToMMScale`-free center coords (emit uses point coords; `emitCenterAnchoredGlyph` handles scaling).
- Produces: two `.glyph` DrawCommands (codepoints 0xE0F5 / 0xE0F6) emitted around a parenthesized notehead. This test also proves Task 7 (carry).

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/AndroidJNI/LayoutBridgeNoteParenthesesTests.swift`:

```swift
#if !os(Android)
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicAndroidJNI
    import Testing

    struct LayoutBridgeNoteParenthesesTests {
        private let _installApple = TestSupport.installApple

        private func glyphCodepoints(parentheses: NoteParentheses) throws -> [UInt32] {
            let note = Note(pitch: 60, tpc: 14, parentheses: parentheses)
            let measure = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [note])),
            ])])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [measure])],
                )],
            )
            let encoded = LayoutBridge.compute(
                score: score, pageWidthMM: 210, pageHeightMM: 297,
            )
            let pages = try DrawProgramCodec.decode(encoded)
            var cps: [UInt32] = []
            for page in pages {
                for cmd in page.commands {
                    if case let .glyph(cp, _, _, _, _) = cmd { cps.append(cp) }
                }
            }
            return cps
        }

        @Test func bothParenthesesEmitLeftAndRightGlyphs() throws {
            let cps = try glyphCodepoints(parentheses: .both)
            #expect(cps.contains(0xE0F5)) // noteheadParenthesisLeft
            #expect(cps.contains(0xE0F6)) // noteheadParenthesisRight
        }

        @Test func noneEmitsNeitherParenthesis() throws {
            let cps = try glyphCodepoints(parentheses: .none)
            #expect(!cps.contains(0xE0F5))
            #expect(!cps.contains(0xE0F6))
        }
    }
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LayoutBridgeNoteParenthesesTests`
Expected: FAIL — `bothParenthesesEmitLeftAndRightGlyphs` finds neither codepoint (emit not implemented).

(If `DrawCommand.glyph`'s associated-value arity differs, fix the pattern `case let .glyph(cp, _, _, _, _)` to match its actual shape — see `Sources/SheetMusicAndroidJNI` `DrawCommand` definition. The encode side is `.glyph(codepoint:x:y:size:fontId:)` = 5 values.)

- [ ] **Step 3: Implement the emit**

In `Sources/SheetMusicAndroidJNI/LayoutBridge+Chord.swift`, in `emitNoteGlyphs`, immediately after the head `emitCenterAnchoredGlyph(...)` call (the block ending at line 165) and before the `if let accidental = note.accidental` block (line 169), insert:

```swift
            // Round parentheses around the notehead. Shares glyph + offset
            // helpers with the Apple paths so all three renderers agree.
            let (leftParenCp, rightParenCp) = NoteheadParenthesisGlyph.glyphs(
                for: note.parentheses,
            )
            if leftParenCp != nil || rightParenCp != nil {
                let parenFont = LayoutFont(
                    face: SMuFLFamily.bravura,
                    pointSize: CGFloat(glyphSize),
                )
                let noteheadCenterX = mox + Double(note.origin.x)
                let noteheadCenterY = moy + Double(note.origin.y)
                if let leftParenCp, let lSc = UnicodeScalar(leftParenCp) {
                    let adv = Double(FontMetrics.provider.typographicWidth(
                        text: String(lSc), font: parenFont,
                    ))
                    let cx = Double(NoteheadParenthesisPlacement.leftParenCenterX(
                        noteheadCenterX: CGFloat(noteheadCenterX),
                        parenAdvance: CGFloat(adv),
                        sp: CGFloat(ctx.sp * mag),
                    ))
                    emitCenterAnchoredGlyph(
                        codepoint: leftParenCp,
                        cxPt: cx, cyPt: noteheadCenterY,
                        sizePt: glyphSize, into: &out,
                    )
                }
                if let rightParenCp, let rSc = UnicodeScalar(rightParenCp) {
                    let adv = Double(FontMetrics.provider.typographicWidth(
                        text: String(rSc), font: parenFont,
                    ))
                    let cx = Double(NoteheadParenthesisPlacement.rightParenCenterX(
                        noteheadCenterX: CGFloat(noteheadCenterX),
                        parenAdvance: CGFloat(adv),
                        sp: CGFloat(ctx.sp * mag),
                    ))
                    emitCenterAnchoredGlyph(
                        codepoint: rightParenCp,
                        cxPt: cx, cyPt: noteheadCenterY,
                        sizePt: glyphSize, into: &out,
                    )
                }
            }
```

**Implementer note:** the placement helper internally uses `StemGeometry.attachDx(sp:)`, so feed the **mag-scaled** spatium `ctx.sp * mag` exactly as the accidental path does (line 210) — `attachDx` is linear in `sp`, so this matches Apple's `metrics.sp` for grace/cue chords.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LayoutBridgeNoteParenthesesTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Gate the new Android test file**

Run: `Scripts/gate-android-tests.sh`
Expected: no changes (the file is already wrapped in `#if !os(Android)`), or it confirms the guard.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/LayoutBridge+Chord.swift Tests/SheetMusicTests/AndroidJNI/LayoutBridgeNoteParenthesesTests.swift
git commit -m "feat(android): emit notehead parentheses in LayoutBridge + e2e test"
```

---

### Task 11: Full verification + visual confirmation

**Files:** none (verification only). Possible follow-up tune of `NoteheadParenthesisPlacement.gapSp` / vertical anchor.

- [ ] **Step 1: Full Apple test suite**

Run: `swift test`
Expected: PASS, 100% green (existing suite + all new tests).

- [ ] **Step 2: Lint**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings / 0 errors. (Watch the 300-line file cap on the modified renderer files; `ScoreLayerBuilder+Chord.swift` already carries `// swiftlint:disable file_length` — confirm it still does. If `LayoutBridge+Chord.swift` or `ScoreCanvas.swift` crosses 300, factor the new code into a helper file rather than disabling the rule.)

- [ ] **Step 3: Preflight (Apple stage)**

Run: `Scripts/preflight.sh --apple`
Expected: green (this is the merge gate).

- [ ] **Step 4: Visual confirmation against the real fixture**

The real file `~/Downloads/ロビンソン.mscz` (MuseScore 4.6.5) has six parenthesized notes. It is copyrighted — do **not** commit it or any derivative.

Per the project convention (`feedback_visual_verify_mac`), verify in **SheetMusicExampleMac** (not the iOS simulator), or render via the `RenderPreviews` dev executable / a `#Preview`. Load `ロビンソン.mscz`, navigate to a parenthesized note, and confirm:
- round parentheses hug the notehead on both sides,
- they are vertically centered on the notehead,
- the gap reads correctly (not touching, not floating far away).

If the gap or vertical anchor looks off, tune `NoteheadParenthesisPlacement.gapSp` and/or the y-anchor (the paren glyphs may need a small vertical offset if SMuFL designs them off the notehead center) and re-render. Commit any tuning:

```bash
git add Sources/SheetMusicLayout/Engraving/NoteheadParenthesisPlacement.swift
git commit -m "fix(layout): tune notehead parenthesis gap/anchor against fixture"
```

- [ ] **Step 5: Report completion**

Summarize: all tasks complete, `swift test` green (N tests), `Scripts/preflight.sh --apple` green, visual confirmation done. Hand off to `superpowers:finishing-a-development-branch` for merge.

---

## Self-Review

**Spec coverage:**
- Goal 1 (model on `Note`, carried to layout) → Task 1 + Task 7. ✓
- Goal 2 (MSCX rep1/rep2/rep3) → Task 2 (rep1+rep2) + Task 3 (rep3). ✓
- Goal 3 (MusicXML `<notehead parentheses>`) → Task 4. ✓
- Goal 4 (MSCX export round-trip) → Task 5 (version-aware rep2/rep1, matching the encoder's actual `.v4`/`.v3` targets discovered during planning). ✓
- Goal 5 (render in all three renderers, directional, small-scaled) → Task 8 (CALayer) + Task 9 (Canvas) + Task 10 (Android). Small/cue scaling is automatic: parens use the same `metrics.glyphFontSize` / `glyphSize * mag` as the head. ✓
- Goal 6 (tests + visual) → Tasks 1–6, 10 (automated) + Task 11 (visual). ✓
- Spec non-goal "rep3 spanning multiple notes with one tall paren" → honored: Task 3 sets per-note `.both`. ✓

**Placeholder scan:** no TBD/TODO; every code step has complete code. Two "implementer note" callouts (Canvas `drawGlyph` label order; Android `DrawCommand.glyph` arity) ask the implementer to confirm a signature against a named file before relying on it — these are verification guards, not missing content.

**Type consistency:** `NoteParentheses` (Task 1) is used identically in Tasks 2–10. `parentheses` is the property name on both `Note` and `LayoutChordNote`. `NoteheadParenthesisGlyph.glyphs(for:) -> (left: UInt32?, right: UInt32?)` and `NoteheadParenthesisPlacement.leftParenCenterX/rightParenCenterX(noteheadCenterX:parenAdvance:sp:)` (Task 6) match their call sites in Tasks 8/9/10. `MSCXEncoderOptions(targetVersion:)` / `MSCXVersion.{v2,v3,v4}` (Task 5) match the encoder.
