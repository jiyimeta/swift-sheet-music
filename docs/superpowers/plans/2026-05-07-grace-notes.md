# Grace Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse MuseScore grace-note tags (5 before-types + 3 after-types) into a typed Score model, render them in MIDI with the same time-stealing semantics MuseScore uses, and render them visually as smaller noteheads adjacent to their parent chord (with an `acciaccatura` slash, no beams or auto-slurs).

**Architecture:** Graces are NOT voice elements — they ride on their parent `Chord` via two new fields (`graceNotesBefore`, `graceNotesAfter`) so existing tuplet / beam / cursor logic stays untouched. The MSCX decoder buffers a `pendingGracesBefore` state and attaches it to the next main chord; after-graces attach back onto the most recently emitted chord. The MIDI renderer steals time from `prev.tail` (acciaccatura) or `main.head` (other before-graces) per the table in the spec, and after-graces steal from `main.tail`. Layout emits a new `LayoutElement.graceChord` case whose `relativeX` is computed from a per-grace width budget × index (negative for before, positive for after); the parent chord's `EventColumn` adds the before-budget to its left padding so neighbouring chords don't collide.

**Tech Stack:** Swift 6, SwiftPM. Library targets touched: `SheetMusicCore`, `SheetMusicMSCX`, `SheetMusicMIDI`, `SheetMusicLayout`, `SheetMusicUI`. Test target: `SheetMusicTests` (Swift Testing — `@Test`, `#expect`).

---

## Spec reference

Source: `docs/superpowers/specs/2026-05-07-grace-notes-design.md`. Re-verify any edit against:

- The `<acciaccatura/>` / `<appoggiatura/>` / `<grace4/>` / `<grace16/>` / `<grace32/>` / `<grace8after/>` / `<grace16after/>` / `<grace32after/>` table (spec §"装飾音符の種別と既定値").
- MuseScore C++ reference points (kept as doc comments per CLAUDE.md):
  `engraving/dom/note.h` `NoteType`,
  `engraving/dom/measure/measureread.cpp` `MeasureRead::readChord`,
  `engraving/compat/midi/compatmidirender.cpp` `CompatMidiRender::renderGraceNotesBefore/After`.

## File map

**New:**
- `Sources/SheetMusicCore/Score/GraceType.swift`
- `Sources/SheetMusicCore/Score/GraceChord.swift`
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift`
- `Sources/SheetMusicUI/Rendering/GraceChordRenderer.swift`
- `Tests/SheetMusicTests/GraceNoteParserTests.swift`
- `Tests/SheetMusicTests/GraceNoteMidiTests.swift`
- `Tests/SheetMusicTests/GraceNoteLayoutTests.swift`

**Modified:**
- `Sources/SheetMusicCore/Score/Chord.swift` — add `graceNotesBefore` / `graceNotesAfter` (default `[]`).
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift` — buffer before-graces, attach after-graces to last chord.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift` — add a small helper that tells callers whether a `<Chord>` node carries one of the 8 grace tags.
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` — replace the `case let .chord(chord):` body with a path that calls into `MidiRenderer+Grace.swift`.
- `Sources/SheetMusicLayout/Layout/LayoutElement.swift` — new `case graceChord(...)`.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift` — handle `.graceChord` in vertical translate.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` — emit `.graceChord` elements alongside their parent chord.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Extents.swift` — include grace-note Y in `chordTopExtent`; expose a static `graceBudget` helper.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift` — feed grace budgets into the per-chord left padding of `EventColumn`.
- `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift` — add `graceNoteMag: CGFloat = 0.6`.
- `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift` — switch `.graceChord` → `GraceChordRenderer`.
- `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift` — add `graceNoteSlashStemUp` (U+E564), `graceNoteSlashStemDown` (U+E565).

**Untouched by construction (no edit needed):**
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Beaming.swift` — beam grouping enumerates `voice.elements`. Graces don't sit there (they ride on `Chord.graceNotesBefore/After`), so they're already excluded.
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Glissando.swift` and `+Arpeggio.swift` — both walk `chord.notes` (the *main* chord's notes). The new `renderChordWithGraces` preserves that path verbatim for the main chord; graces have their own `notes` array which never feeds glissando / arpeggio lookups.

**Out of scope (Non-goals from spec):** beams between adjacent graces, automatic grace-to-main slurs, articulations on graces, grace-velocity differentiation, grace editing API. These are explicitly punted to follow-up PRs.

---

## Conventions for every step

- **TDD.** Each task starts with a failing test (or a test that fails to compile because the new symbol doesn't exist), then the minimal code to make it pass, then a verification run. Treat compile errors as a valid "fails" outcome — the harness can't tell them apart from runtime asserts and they prove the symbol was missing.
- **Build / test commands.** From the package root (`/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`):
  - Compile only: `swift build`
  - Suite run: `swift test --filter <Suite>`
  - Lint (must finish clean): `swiftlint --quiet Sources Tests`
- **Commits.** One commit per task, prefixed with the conventional type used in this repo (`feat:`, `fix:`, `test:`, `refactor:` — recent log: `feat(ui)`, `fix(layout)`, `docs(spec)`).
- **Doc comments.** When porting a MuseScore algorithm, leave a `/// Mirrors CompatMidiRender::renderGraceNotesBefore` (or similar) reference. Do not paste GPL code.
- **Public-API additions** that expand a struct take new fields with default values so existing callers compile unchanged.

---

## Task 1: Add `GraceType` enum

**Files:**
- Create: `Sources/SheetMusicCore/Score/GraceType.swift`
- Test: `Tests/SheetMusicTests/GraceNoteParserTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/GraceNoteParserTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("GraceType")
struct GraceTypeTests {
    @Test("isAfter is true exactly for the 3 *after tags")
    func isAfterFlag() {
        #expect(GraceType.acciaccatura.isAfter == false)
        #expect(GraceType.appoggiatura.isAfter == false)
        #expect(GraceType.grace4.isAfter == false)
        #expect(GraceType.grace16.isAfter == false)
        #expect(GraceType.grace32.isAfter == false)
        #expect(GraceType.grace8after.isAfter == true)
        #expect(GraceType.grace16after.isAfter == true)
        #expect(GraceType.grace32after.isAfter == true)
    }

    @Test("mscxTag round-trips every case")
    func mscxTagRoundTrip() {
        let all: [GraceType] = [
            .acciaccatura, .appoggiatura,
            .grace4, .grace16, .grace32,
            .grace8after, .grace16after, .grace32after,
        ]
        for g in all {
            #expect(GraceType(mscxTag: g.mscxTag) == g)
        }
        #expect(GraceType(mscxTag: "Note") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GraceTypeTests`
Expected: FAIL — "cannot find type 'GraceType' in scope".

- [ ] **Step 3: Write the type**

Create `Sources/SheetMusicCore/Score/GraceType.swift`:

```swift
import Foundation

/// Grace-note category. Subset of MuseScore's `NoteType` (the
/// non-grace cases — `NORMAL`, `INVALID` — are out of scope here).
/// C++: `mu::engraving::NoteType` (`engraving/dom/note.h`).
public enum GraceType: Sendable, Equatable, CaseIterable {
    case acciaccatura
    case appoggiatura
    case grace4
    case grace16
    case grace32
    case grace8after
    case grace16after
    case grace32after

    /// True for after-grace types (`grace8after` / `grace16after` /
    /// `grace32after`). MuseScore writes these *after* the parent
    /// chord in the mscx stream; we attach them to the most recent
    /// chord seen in the voice.
    public var isAfter: Bool {
        switch self {
        case .grace8after, .grace16after, .grace32after: true
        default: false
        }
    }

    /// MSCX child-tag spelling. The decoder maps `<acciaccatura/>`
    /// → `.acciaccatura`, etc. Stable across MuseScore 3 / 4.
    public var mscxTag: String {
        switch self {
        case .acciaccatura: "acciaccatura"
        case .appoggiatura: "appoggiatura"
        case .grace4: "grace4"
        case .grace16: "grace16"
        case .grace32: "grace32"
        case .grace8after: "grace8after"
        case .grace16after: "grace16after"
        case .grace32after: "grace32after"
        }
    }

    /// Reverse of `mscxTag`. Returns `nil` for any non-grace tag.
    public init?(mscxTag: String) {
        guard let match = Self.allCases.first(where: { $0.mscxTag == mscxTag })
        else { return nil }
        self = match
    }
}
```

- [ ] **Step 4: Verify the test passes**

Run: `swift test --filter GraceTypeTests`
Expected: PASS (2 tests in the suite).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/GraceType.swift Tests/SheetMusicTests/GraceNoteParserTests.swift
git commit -m "feat(core): add GraceType enum"
```

---

## Task 2: Add `GraceChord` struct

**Files:**
- Create: `Sources/SheetMusicCore/Score/GraceChord.swift`
- Test: `Tests/SheetMusicTests/GraceNoteParserTests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append a new suite to `Tests/SheetMusicTests/GraceNoteParserTests.swift` (above the closing brace of the file — keep `GraceTypeTests` intact):

```swift
@Suite("GraceChord")
struct GraceChordTests {
    @Test("Stores graceType, duration, notes; Equatable")
    func basics() {
        let n = Note(pitch: 60, tpc: 14)
        let g = GraceChord(
            graceType: .acciaccatura,
            duration: .eighth,
            notes: ChordNotes([n])
        )
        #expect(g.graceType == .acciaccatura)
        #expect(g.duration == .eighth)
        #expect(g.notes.count == 1)
        #expect(g == GraceChord(
            graceType: .acciaccatura,
            duration: .eighth,
            notes: ChordNotes([n])
        ))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GraceChordTests`
Expected: FAIL — "cannot find type 'GraceChord' in scope".

- [ ] **Step 3: Write the type**

Create `Sources/SheetMusicCore/Score/GraceChord.swift`:

```swift
import Foundation

/// A grace-note chord that rides on a `Chord`'s `graceNotesBefore`
/// or `graceNotesAfter` rather than living in `Voice.elements`.
///
/// Why it isn't a `VoiceElement`: graces don't consume voice time —
/// keeping them off `Voice.elements` means tuplet `startIndex /
/// endIndex` semantics, beam grouping (which iterates voice
/// elements), and the cursor-tick walks all stay untouched.
///
/// `duration` here is *visual* (number of stem flags / beams in
/// engraving) — playback length is decided by `MidiRenderer+Grace`
/// from `graceType` + the parent chord's tick length, not by
/// `duration.ticks(division:)`.
///
/// C++: `mu::engraving::Chord` whose `_noteType` is one of the
/// grace cases of `NoteType`.
public struct GraceChord: Sendable, Equatable {
    public var graceType: GraceType
    public var duration: NoteDuration
    public var notes: ChordNotes

    public init(
        graceType: GraceType,
        duration: NoteDuration,
        notes: ChordNotes
    ) {
        self.graceType = graceType
        self.duration = duration
        self.notes = notes
    }
}
```

- [ ] **Step 4: Verify the test passes**

Run: `swift test --filter GraceChordTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/GraceChord.swift Tests/SheetMusicTests/GraceNoteParserTests.swift
git commit -m "feat(core): add GraceChord value type"
```

---

## Task 3: Extend `Chord` with `graceNotesBefore` / `graceNotesAfter`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Chord.swift`
- Test: `Tests/SheetMusicTests/GraceNoteParserTests.swift` (append)

Defaults of `[]` keep existing call sites compiling untouched.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/GraceNoteParserTests.swift`:

```swift
@Suite("Chord with graces")
struct ChordWithGracesTests {
    @Test("Default init leaves grace arrays empty (source compat)")
    func defaultsEmpty() {
        let c = Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))
        #expect(c.graceNotesBefore.isEmpty)
        #expect(c.graceNotesAfter.isEmpty)
    }

    @Test("graceNotesBefore / After are stored and Equatable")
    func storesGraces() {
        let g = GraceChord(
            graceType: .acciaccatura, duration: .eighth,
            notes: ChordNotes([Note(pitch: 62, tpc: 16)])
        )
        let c = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            graceNotesBefore: [g],
            graceNotesAfter: []
        )
        #expect(c.graceNotesBefore == [g])
        #expect(c.graceNotesAfter.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "ChordWithGracesTests"`
Expected: FAIL — extra arguments at positions, or "no exact matches in call".

- [ ] **Step 3: Modify `Chord.swift`**

Replace the contents of `Sources/SheetMusicCore/Score/Chord.swift` with:

```swift
import Foundation

/// A simultaneously-sounding group of notes with a shared duration.
/// C++: `mu::engraving::Chord` (subset).
public struct Chord: Sendable, Equatable {
    public var duration: NoteDuration
    /// Notes belonging to this chord. The pitch-uniqueness
    /// invariant lives in `ChordNotes` itself: assignments,
    /// appends, and in-place mutations all dedupe by `Note.pitch`.
    public var notes: ChordNotes
    /// Optional arpeggio that spreads the chord's notes in time.
    public var arpeggio: Arpeggio?
    /// Lyrics syllable(s) attached to this chord, one per verse line.
    /// Most scores use a single verse (index 0). C++: `mu::engraving::Lyrics`.
    public var lyrics: [Lyric]
    /// Grace notes that play *before* this chord. Stored in mscx
    /// (left-to-right) order. They don't consume voice time —
    /// `MidiRenderer+Grace` steals from this chord's head or the
    /// previous chord's tail to fit them in.
    public var graceNotesBefore: [GraceChord]
    /// Grace notes that play *after* this chord. Same conventions
    /// as `graceNotesBefore`; their playback time is stolen from
    /// the tail of this chord.
    public var graceNotesAfter: [GraceChord]

    public init(
        duration: NoteDuration,
        notes: ChordNotes,
        arpeggio: Arpeggio? = nil,
        lyrics: [Lyric] = [],
        graceNotesBefore: [GraceChord] = [],
        graceNotesAfter: [GraceChord] = []
    ) {
        self.duration = duration
        self.notes = notes
        self.arpeggio = arpeggio
        self.lyrics = lyrics
        self.graceNotesBefore = graceNotesBefore
        self.graceNotesAfter = graceNotesAfter
    }
}
```

- [ ] **Step 4: Build whole package**

Run: `swift build`
Expected: PASS — the new defaulted fields don't break any existing call site.

- [ ] **Step 5: Run the new test**

Run: `swift test --filter ChordWithGracesTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/Score/Chord.swift Tests/SheetMusicTests/GraceNoteParserTests.swift
git commit -m "feat(core): add Chord.graceNotesBefore / graceNotesAfter"
```

---

## Task 4: MSCX — detect grace tag inside `<Chord>`

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`
- Test: `Tests/SheetMusicTests/GraceNoteParserTests.swift` (append)

We add a tiny pure helper that, given an `XMLTreeNode` representing a `<Chord>`, returns the `GraceType` if any of its direct children is one of the 8 grace tags. This isolates the tag-sniffing logic and lets `MSCXDecoder+Voice` stay readable.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/GraceNoteParserTests.swift`:

```swift
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools

@Suite("Chord grace detection")
struct ChordGraceDetectionTests {
    private func chordNode(_ xml: String) -> XMLTreeNode {
        let parsed = try? XMLTreeParser.parse(Data(xml.utf8))
        return parsed!
    }

    @Test("acciaccatura tag detected")
    func acciaccatura() throws {
        let node = chordNode("""
        <Chord><acciaccatura/><durationType>eighth</durationType>\
        <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        """)
        #expect(Chord.graceType(in: node) == .acciaccatura)
    }

    @Test("grace32after tag detected")
    func grace32after() throws {
        let node = chordNode("""
        <Chord><grace32after/><durationType>32nd</durationType>\
        <Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
        """)
        #expect(Chord.graceType(in: node) == .grace32after)
    }

    @Test("Plain chord returns nil")
    func plain() throws {
        let node = chordNode("""
        <Chord><durationType>quarter</durationType>\
        <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        """)
        #expect(Chord.graceType(in: node) == nil)
    }
}
```

- [ ] **Step 2: Run to confirm it fails**

Run: `swift test --filter ChordGraceDetectionTests`
Expected: FAIL — "type 'Chord' has no member 'graceType'".

- [ ] **Step 3: Add the helper**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`, append (still inside `extension Chord`, after the existing `decode(_:)` method):

```swift
    /// Inspect a `<Chord>` node and return its grace category if any
    /// of the 8 grace child-tags is present. nil = ordinary chord.
    /// C++: `MeasureRead::readChord` sets `_noteType` from these tags
    /// (`engraving/dom/measure/measureread.cpp`).
    static func graceType(in node: XMLTreeNode) -> GraceType? {
        for child in node.children {
            if let g = GraceType(mscxTag: child.name) { return g }
        }
        return nil
    }
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter ChordGraceDetectionTests`
Expected: PASS (3 cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift Tests/SheetMusicTests/GraceNoteParserTests.swift
git commit -m "feat(mscx): detect grace tag in <Chord> via Chord.graceType(in:)"
```

---

## Task 5: MSCX — wire graces into voice decoding

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift`
- Test: `Tests/SheetMusicTests/GraceNoteParserTests.swift` (append)

The decoder buffers `pendingGracesBefore`. When the next normal chord lands, the buffer becomes that chord's `graceNotesBefore`. When an after-grace lands, we mutate the most recently emitted `.chord` in `elements` to append it to `graceNotesAfter`. Tuplet ratios do *not* scale grace duration — graces don't contribute to tuplet wall-clock time.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/GraceNoteParserTests.swift`:

```swift
@Suite("Voice grace attachment")
struct VoiceGraceAttachmentTests {
    private func voiceXML(_ inner: String) throws -> Voice {
        let xml = "<voice>\(inner)</voice>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Voice.decode(node)
    }

    private func chordXML(
        _ tag: String? = nil, dur: String, pitch: Int, tpc: Int
    ) -> String {
        let g = tag.map { "<\($0)/>" } ?? ""
        return """
        <Chord>\(g)<durationType>\(dur)</durationType>\
        <Note><pitch>\(pitch)</pitch><tpc>\(tpc)</tpc></Note></Chord>
        """
    }

    @Test("acciaccatura before main chord attaches as graceNotesBefore")
    func beforeAttaches() throws {
        let v = try voiceXML(
            chordXML("acciaccatura", dur: "eighth", pitch: 62, tpc: 16)
                + chordXML(dur: "quarter", pitch: 60, tpc: 14)
        )
        #expect(v.elements.count == 1)
        guard case let .chord(c) = v.elements[0] else {
            Issue.record("expected single .chord"); return
        }
        #expect(c.graceNotesBefore.count == 1)
        #expect(c.graceNotesBefore[0].graceType == .acciaccatura)
        #expect(c.graceNotesBefore[0].notes.first?.pitch == 62)
        #expect(c.graceNotesAfter.isEmpty)
    }

    @Test("Multiple before-graces preserve mscx order")
    func beforeOrder() throws {
        let v = try voiceXML(
            chordXML("grace16", dur: "16th", pitch: 64, tpc: 18)
                + chordXML("grace16", dur: "16th", pitch: 65, tpc: 13)
                + chordXML(dur: "quarter", pitch: 60, tpc: 14)
        )
        guard case let .chord(c) = v.elements.first else {
            Issue.record("no chord"); return
        }
        #expect(c.graceNotesBefore.map { $0.notes.first?.pitch } == [64, 65])
    }

    @Test("grace8after attaches to preceding chord")
    func afterAttaches() throws {
        let v = try voiceXML(
            chordXML(dur: "quarter", pitch: 60, tpc: 14)
                + chordXML("grace8after", dur: "eighth", pitch: 62, tpc: 16)
        )
        #expect(v.elements.count == 1)
        guard case let .chord(c) = v.elements[0] else { return }
        #expect(c.graceNotesAfter.count == 1)
        #expect(c.graceNotesAfter[0].graceType == .grace8after)
    }

    @Test("Stranded before-graces (no following main chord) are dropped")
    func stranded() throws {
        let v = try voiceXML(chordXML("acciaccatura", dur: "eighth", pitch: 62, tpc: 16))
        #expect(v.elements.isEmpty)
    }

    @Test("Stranded after-grace (no preceding chord) is dropped")
    func strandedAfter() throws {
        let v = try voiceXML(chordXML("grace8after", dur: "eighth", pitch: 62, tpc: 16))
        #expect(v.elements.isEmpty)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter VoiceGraceAttachmentTests`
Expected: FAIL — graces currently land as ordinary chords in `elements`, so counts won't match.

- [ ] **Step 3: Modify the `<Chord>` arm of `Voice.decode`**

Open `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift`. Replace the entire `static func decode(_:)` body's `case "Chord":` branch (currently lines 29-34) with the grace-aware version. The full new method body is below (re-paste verbatim — it's the existing logic with the `<Chord>` case rewritten and a new `pendingGracesBefore` local; everything else is unchanged):

```swift
    static func decode(_ node: XMLTreeNode) throws -> Voice {
        var elements: [VoiceElement] = []
        elements.reserveCapacity(node.children.count)
        var tuplets: [Tuplet] = []
        var tupletStack: [OpenTuplet] = []
        // Buffer for `<Chord><acciaccatura/>...` etc. encountered
        // before the next ordinary chord in this voice. Cleared
        // whenever attached to the next main `Chord`. Stranded
        // entries (left over at end-of-voice) are dropped — MuseScore
        // doesn't play them either.
        var pendingGracesBefore: [GraceChord] = []
        func tupletFractions() -> [Fraction] {
            tupletStack.map(\.ratio)
        }
        for child in node.children {
            switch child.name {
            case "Chord":
                if let graceType = Chord.graceType(in: child) {
                    // Decode shape but do NOT scale by tuplet ratios:
                    // graces don't consume tuplet time — see
                    // CompatMidiRender::renderGraceNotesBefore.
                    let inner = try Chord.decode(child)
                    let g = GraceChord(
                        graceType: graceType,
                        duration: inner.duration,
                        notes: inner.notes
                    )
                    if graceType.isAfter {
                        // Attach to the most recently emitted chord.
                        // Walk backwards because tempo / dynamic /
                        // location elements may sit between the
                        // grace and its parent chord.
                        for i in stride(from: elements.count - 1, through: 0, by: -1) {
                            if case var .chord(parent) = elements[i] {
                                parent.graceNotesAfter.append(g)
                                elements[i] = .chord(parent)
                                break
                            }
                        }
                        // No preceding chord → drop silently.
                    } else {
                        pendingGracesBefore.append(g)
                    }
                    continue
                }
                var chord = try Chord.decode(child)
                chord.duration = scaled(
                    chord.duration, by: tupletFractions()
                )
                if !pendingGracesBefore.isEmpty {
                    chord.graceNotesBefore = pendingGracesBefore
                    pendingGracesBefore.removeAll(keepingCapacity: true)
                }
                elements.append(.chord(chord))
            case "Rest":
                var rest = try MSCXRestDecoder.decode(child)
                rest.duration = scaled(
                    rest.duration, by: tupletFractions()
                )
                elements.append(.chord(rest))
            case "Tuplet":
                if let ratio = tupletRatio(from: child) {
                    tupletStack.append(OpenTuplet(
                        ratio: ratio,
                        firstElementIndex: elements.count
                    ))
                }
            case "endTuplet":
                if let top = tupletStack.popLast() {
                    let endIndex = elements.count - 1
                    if endIndex >= top.firstElementIndex {
                        tuplets.append(Tuplet(
                            normalNotes: top.ratio.numerator,
                            actualNotes: top.ratio.denominator,
                            startIndex: top.firstElementIndex,
                            endIndex: endIndex
                        ))
                    }
                }
            case "KeySig":
                try elements.append(.keySignature(KeySignature.decode(child)))
            case "TimeSig":
                try elements.append(.timeSignature(TimeSignature.decode(child)))
            case "Clef":
                try elements.append(.clef(Clef.decode(child)))
            case "BarLine":
                try elements.append(.barLine(BarLine.decode(child)))
            case "Tempo":
                try elements.append(.tempo(Tempo.decode(child)))
            case "Dynamic":
                try elements.append(.dynamic(Dynamic.decode(child)))
            case "Spanner":
                try elements.append(.spanner(Spanner.decode(child)))
            case "MeasureRepeat", "RepeatMeasure":
                try elements.append(.measureRepeat(MeasureRepeat.decode(child)))
            case "Fermata":
                let subtype = child.first("subtype")?.text ?? ""
                elements.append(.fermata(Fermata(subtype: subtype)))
            case "StaffText":
                try elements.append(.staffText(
                    StaffText.decode(child, isSystemText: false)))
            case "SystemText":
                try elements.append(.staffText(
                    StaffText.decode(child, isSystemText: true)))
            case "Harmony":
                try elements.append(.harmony(Harmony.decode(child)))
            case "RehearsalMark":
                try elements.append(.rehearsalMark(
                    RehearsalMark.decode(child)))
            case "location":
                if let fracText = child.first("fractions")?.text,
                   let frac = Fraction(mscxString: fracText)
                {
                    elements.append(.locationShift(delta: frac))
                }
            default:
                continue
            }
        }
        // Stranded `pendingGracesBefore` (no following chord in this
        // voice) intentionally dropped — see comment on the buffer.
        return Voice(elements: elements, tuplets: tuplets)
    }
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter VoiceGraceAttachmentTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full MSCX-related test suites for regression**

Run: `swift test --filter MidiExportTests`
Expected: PASS (12 cases). (Existing scores have no graces, so behaviour is unchanged.)

- [ ] **Step 6: Lint**

Run: `swiftlint --quiet Sources/SheetMusicMSCX Tests/SheetMusicTests/GraceNoteParserTests.swift`
Expected: 0 warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift Tests/SheetMusicTests/GraceNoteParserTests.swift
git commit -m "feat(mscx): attach grace notes to neighbouring main Chord"
```

---

## Task 6: MIDI — `MidiRenderer+Grace.swift` helpers

**Files:**
- Create: `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift`
- Test: `Tests/SheetMusicTests/GraceNoteMidiTests.swift`

Pure functions, no `events: inout` work yet. Wiring into the voice walk happens in Task 7.

- [ ] **Step 1: Create the new test file**

Create `Tests/SheetMusicTests/GraceNoteMidiTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite("MidiRenderer.playbackTicks")
struct GracePlaybackTicksTests {
    private let division = 480 // PPQ used by every other MIDI test

    @Test("acciaccatura → 1/32 of a quarter note (= division/8)")
    func acciaccatura() {
        let g = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [])
        #expect(MidiRenderer.playbackTicks(
            for: g, mainTicks: division, division: division
        ) == division / 8)
    }

    @Test("appoggiatura → half of mainTicks")
    func appoggiatura() {
        let g = GraceChord(graceType: .appoggiatura, duration: .quarter, notes: [])
        #expect(MidiRenderer.playbackTicks(
            for: g, mainTicks: division, division: division
        ) == division / 2)
    }

    @Test("grace4 / grace16 / grace32 use fixed durations")
    func fixedFractions() {
        let mk = { (gt: GraceType) in
            GraceChord(graceType: gt, duration: .eighth, notes: [])
        }
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace4), mainTicks: division, division: division
        ) == division)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace16), mainTicks: division, division: division
        ) == division / 4)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace32), mainTicks: division, division: division
        ) == division / 8)
    }

    @Test("grace8/16/32after use 1/8, 1/16, 1/32 of a quarter")
    func afterFixed() {
        let mk = { (gt: GraceType) in
            GraceChord(graceType: gt, duration: .eighth, notes: [])
        }
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace8after), mainTicks: division, division: division
        ) == division / 2)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace16after), mainTicks: division, division: division
        ) == division / 4)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace32after), mainTicks: division, division: division
        ) == division / 8)
    }
}

@Suite("MidiRenderer.totalSteal")
struct GraceTotalStealTests {
    private let division = 480

    @Test("totalStealFromPrev = sum of acciaccatura ticks only")
    func stealPrev() {
        let g1 = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [])
        let g2 = GraceChord(graceType: .grace16,      duration: .sixteenth, notes: [])
        #expect(MidiRenderer.totalStealFromPrev([g1, g2], division: division)
                == division / 8)
    }

    @Test("totalStealFromMainHead = sum of non-acciaccatura before-grace ticks")
    func stealHead() {
        let g1 = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [])
        let g2 = GraceChord(graceType: .grace16,      duration: .sixteenth, notes: [])
        #expect(MidiRenderer.totalStealFromMainHead(
            [g1, g2], mainTicks: division, division: division
        ) == division / 4)
    }

    @Test("Head steal capped at mainTicks/2 when graces overflow")
    func headCap() {
        // Three grace4 → 3 * 480 = 1440, but main is 480 → cap to 240.
        let four = (0 ..< 3).map { _ in
            GraceChord(graceType: .grace4, duration: .quarter, notes: [])
        }
        #expect(MidiRenderer.totalStealFromMainHead(
            four, mainTicks: division, division: division
        ) == division / 2)
    }

    @Test("totalStealFromMainTail sums after-grace ticks (capped at half)")
    func stealTail() {
        let g = GraceChord(graceType: .grace8after, duration: .eighth, notes: [])
        #expect(MidiRenderer.totalStealFromMainTail(
            [g], mainTicks: division, division: division
        ) == division / 2)
        let many = (0 ..< 4).map { _ in g }
        #expect(MidiRenderer.totalStealFromMainTail(
            many, mainTicks: division, division: division
        ) == division / 2) // capped
    }
}
```

- [ ] **Step 2: Verify the tests fail to compile**

Run: `swift test --filter GracePlaybackTicksTests`
Expected: FAIL — "type 'MidiRenderer' has no member 'playbackTicks'".

- [ ] **Step 3: Implement the helpers**

Create `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift`:

```swift
import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// Default playback length of one grace note in ticks.
    /// Mirrors `CompatMidiRender::graceTickLen` — appoggiatura is
    /// proportional to the parent (`mainTicks/2`); the rest are
    /// constants in PPQ. `acciaccatura` is intentionally short
    /// (1/32 of a quarter) so it reads as a "crushed" ornament.
    static func playbackTicks(
        for grace: GraceChord, mainTicks: Int, division: Int
    ) -> Int {
        switch grace.graceType {
        case .acciaccatura:    return division / 8     // 1/32 of a quarter
        case .appoggiatura:    return max(0, mainTicks / 2)
        case .grace4:          return division          // 1/4 = quarter
        case .grace16:         return division / 4
        case .grace32:         return division / 8
        case .grace8after:     return division / 2
        case .grace16after:    return division / 4
        case .grace32after:    return division / 8
        }
    }

    /// Time stolen from the *previous* chord's tail. Only
    /// acciaccaturas steal from the previous chord; every other
    /// before-grace steals from the parent chord's head.
    /// Mirrors `CompatMidiRender::renderGraceNotesBefore`.
    static func totalStealFromPrev(
        _ before: [GraceChord], division: Int
    ) -> Int {
        before.reduce(0) { acc, g in
            g.graceType == .acciaccatura
                ? acc + playbackTicks(for: g, mainTicks: 0, division: division)
                : acc
        }
    }

    /// Time stolen from the *parent* chord's head. Sum of every
    /// before-grace's playback length, EXCEPT acciaccatura (which
    /// steals from the previous chord). Capped at mainTicks/2 to
    /// keep the parent audible — MuseScore's
    /// `handleOverflowsForGrace` does a non-linear shrink; we do
    /// a single proportional clamp because it handles every realistic
    /// score and stays simple.
    static func totalStealFromMainHead(
        _ before: [GraceChord], mainTicks: Int, division: Int
    ) -> Int {
        let raw = before.reduce(0) { acc, g in
            g.graceType == .acciaccatura
                ? acc
                : acc + playbackTicks(for: g, mainTicks: mainTicks, division: division)
        }
        return min(raw, max(0, mainTicks / 2))
    }

    /// Time stolen from the *parent* chord's tail to fit
    /// after-graces. Same capping rule as the head.
    static func totalStealFromMainTail(
        _ after: [GraceChord], mainTicks: Int, division: Int
    ) -> Int {
        let raw = after.reduce(0) { acc, g in
            acc + playbackTicks(for: g, mainTicks: mainTicks, division: division)
        }
        return min(raw, max(0, mainTicks / 2))
    }
}
```

- [ ] **Step 4: Run the helper tests**

Run: `swift test --filter "GracePlaybackTicksTests|GraceTotalStealTests"`
Expected: PASS.

- [ ] **Step 5: Lint**

Run: `swiftlint --quiet Sources/SheetMusicMIDI`
Expected: 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift Tests/SheetMusicTests/GraceNoteMidiTests.swift
git commit -m "feat(midi): add grace-note tick helpers"
```

---

## Task 7: MIDI — wire graces into voice rendering

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`
- Test: `Tests/SheetMusicTests/GraceNoteMidiTests.swift` (append)

The integration changes how a single chord with graces emits events. Cursor advancement (`localTick += chord.duration.ticks`) is unchanged: graces sit *inside* the chord's time slice.

- [ ] **Step 1: Write the failing integration tests**

Append to `Tests/SheetMusicTests/GraceNoteMidiTests.swift`:

```swift
@Suite("Grace MIDI integration")
struct GraceMidiIntegrationTests {
    /// Build a single-staff, single-voice score with `chords` as
    /// the body of measure 0. Returns the rendered events and the PPQ.
    private func render(_ chords: [Chord]) -> (events: [TimedMidiEvent], ppq: Int) {
        let measure = Measure(voices: [Voice(elements: chords.map { .chord($0) })])
        let staff = Staff(measures: [measure])
        let part = Part(instrument: Instrument(name: "piano"), staves: [staff])
        let score = Score(parts: [part])
        let file = MidiRenderer.render(score: score)
        return (file.tracks.flatMap(\.events), Int(file.division))
    }

    private func note(_ pitch: Int) -> Note { Note(pitch: pitch, tpc: 14) }

    @Test("acciaccatura: prev chord noteOff is pulled in by grace ticks")
    func acciaccaturaStealsPrev() {
        let prev = Chord(duration: .quarter, notes: ChordNotes([note(60)]))
        let main = Chord(
            duration: .quarter,
            notes: ChordNotes([note(64)]),
            graceNotesBefore: [GraceChord(
                graceType: .acciaccatura, duration: .eighth,
                notes: ChordNotes([note(62)])
            )]
        )
        let (events, ppq) = render([prev, main])
        let prevOff = events.first { e in
            if case let .noteOff(_, p, _) = e.event, p == 60 { return true }
            return false
        }
        // prev quarter starts at 0 with gate ≈ 100% → off ~ ppq-1.
        // Acciaccatura steals ppq/8.
        #expect(prevOff?.tick == ppq - 1 - ppq / 8)

        // Grace note-on lands BEFORE main onset (= ppq).
        let graceOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 62 { return true }
            return false
        }
        #expect(graceOn?.tick == ppq - ppq / 8)

        // Main onset still at ppq (acciaccatura doesn't shift main).
        let mainOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 64 { return true }
            return false
        }
        #expect(mainOn?.tick == ppq)
    }

    @Test("appoggiatura: main onset shifts forward by grace ticks")
    func appoggiaturaStealsMain() {
        let main = Chord(
            duration: .quarter,
            notes: ChordNotes([note(60)]),
            graceNotesBefore: [GraceChord(
                graceType: .appoggiatura, duration: .eighth,
                notes: ChordNotes([note(62)])
            )]
        )
        let (events, ppq) = render([main])
        let graceOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 62 { return true }; return false
        }
        let mainOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 60 { return true }; return false
        }
        #expect(graceOn?.tick == 0)
        #expect(mainOn?.tick == ppq / 2)
    }

    @Test("grace8after: emitted after main, main tail shortened")
    func afterGrace() {
        let main = Chord(
            duration: .quarter,
            notes: ChordNotes([note(60)]),
            graceNotesAfter: [GraceChord(
                graceType: .grace8after, duration: .eighth,
                notes: ChordNotes([note(62)])
            )]
        )
        let (events, ppq) = render([main])
        let mainOff = events.first { e in
            if case let .noteOff(_, p, _) = e.event, p == 60 { return true }; return false
        }
        let graceOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 62 { return true }; return false
        }
        // Main quarter = ppq ticks, tail steal = ppq/2 → main plays
        // for ppq/2; off-tick = mainOnset + playedTicks - 1 = ppq/2 - 1.
        #expect(mainOff?.tick == ppq / 2 - 1)
        #expect(graceOn?.tick == ppq / 2)
    }

    @Test("acciaccatura on first chord: steal-from-prev gracefully clamps")
    func acciaccaturaNoPrev() {
        // No previous chord → graceTick would be negative; renderer
        // must clamp and still emit grace + main without crashing.
        let main = Chord(
            duration: .quarter,
            notes: ChordNotes([note(60)]),
            graceNotesBefore: [GraceChord(
                graceType: .acciaccatura, duration: .eighth,
                notes: ChordNotes([note(62)])
            )]
        )
        let (events, _) = render([main])
        let graceOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 62 { return true }; return false
        }
        #expect(graceOn?.tick == 0) // clamped to ≥ 0
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter GraceMidiIntegrationTests`
Expected: FAIL — current renderer ignores `graceNotesBefore`/`graceNotesAfter`.

- [ ] **Step 3: Replace the chord-rendering case**

In `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`, find this block (around line 163):

```swift
        case let .chord(chord):
            let glissandoEndPitch = chord.notes.contains(where: { $0.glissando != nil })
                ? MidiRenderer.glissandoEndPitch(
                    voiceElements: voiceElements,
                    afterElementIndex: elementIndex,
                    measures: measures,
                    measureIndex: measureIndex,
                    voiceIndex: voiceIndex
                )
                : nil
            renderChord(
                chord,
                tick: localTick,
                velocity: velocity,
                channel: channel,
                instrument: instrument,
                tempoBps: currentTempoBps,
                division: division,
                glissandoEndPitch: glissandoEndPitch,
                currentKey: currentKey,
                events: &events
            )
            localTick += chord.duration.ticks(division: division)
```

Replace with the grace-aware version (only this block — leave everything else in the file alone):

```swift
        case let .chord(chord):
            let glissandoEndPitch = chord.notes.contains(where: { $0.glissando != nil })
                ? MidiRenderer.glissandoEndPitch(
                    voiceElements: voiceElements,
                    afterElementIndex: elementIndex,
                    measures: measures,
                    measureIndex: measureIndex,
                    voiceIndex: voiceIndex
                )
                : nil
            renderChordWithGraces(
                chord,
                tick: localTick,
                velocity: velocity,
                channel: channel,
                instrument: instrument,
                tempoBps: currentTempoBps,
                division: division,
                glissandoEndPitch: glissandoEndPitch,
                currentKey: currentKey,
                events: &events
            )
            localTick += chord.duration.ticks(division: division)
```

- [ ] **Step 4: Add the wrapper inside `MidiRenderer+Grace.swift`**

Append to `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift` (inside the same `extension MidiRenderer { ... }` block as the helpers from Task 6):

```swift
    /// Render one parent chord and its surrounding grace notes.
    /// Steals time per the helpers above:
    ///
    ///   prev.tail   ─stealFromPrev─►  before-graces (acciaccatura only)
    ///   main.head   ─stealFromHead─►  before-graces (everything else)
    ///   main.tail   ─stealFromTail─►  after-graces
    ///
    /// Mirrors `CompatMidiRender::renderGraceNotesBefore` /
    /// `renderGraceNotesAfter` semantics, simplified for this codebase
    /// (no per-grace velocity scaling — see spec Non-goals).
    // swiftlint:disable:next function_parameter_count
    static func renderChordWithGraces(
        _ chord: Chord,
        tick: Int,
        velocity: Int,
        channel: Int,
        instrument: Instrument,
        tempoBps: Double,
        division: Int,
        glissandoEndPitch: Int?,
        currentKey: Int,
        events: inout [TimedMidiEvent]
    ) {
        let mainTicks = chord.duration.ticks(division: division)
        let stealFromPrev = totalStealFromPrev(
            chord.graceNotesBefore, division: division
        )
        let stealFromHead = totalStealFromMainHead(
            chord.graceNotesBefore, mainTicks: mainTicks, division: division
        )
        let stealFromTail = totalStealFromMainTail(
            chord.graceNotesAfter, mainTicks: mainTicks, division: division
        )

        // 1. Pull preceding noteOffs (this voice / channel only) back
        // by `stealFromPrev`, clamped so they never precede their
        // own noteOn. Without this clamp a back-to-back acciaccatura
        // followed by a very short prev chord would overlap.
        if stealFromPrev > 0 {
            let prevNoteOnTicks = collectPriorNoteOnTicks(
                in: events, channel: channel
            )
            for i in events.indices.reversed() {
                guard events[i].tick <= tick - 1,
                      events[i].tick > tick - 1 - stealFromPrev,
                      case let .noteOff(ch, pitch, vel) = events[i].event,
                      ch == channel
                else { continue }
                let onTick = prevNoteOnTicks[pitch] ?? events[i].tick
                let target = max(onTick + 1, events[i].tick - stealFromPrev)
                events[i] = TimedMidiEvent(
                    tick: target,
                    event: .noteOff(channel: ch, pitch: pitch, velocity: vel)
                )
            }
        }

        // 2. Emit before-graces. Two independent cursors so an
        // acciaccatura order-mixed with non-acciaccaturas still
        // lands in the correct steal-region:
        //   prevCursor walks the [tick - stealFromPrev, tick) slot
        //   headCursor walks the [tick, tick + stealFromHead)  slot
        var prevCursor = max(0, tick - stealFromPrev)
        var headCursor = tick
        for g in chord.graceNotesBefore {
            let dur = playbackTicks(
                for: g, mainTicks: mainTicks, division: division
            )
            let onset: Int
            if g.graceType == .acciaccatura {
                onset = prevCursor
                prevCursor += dur
            } else {
                onset = headCursor
                headCursor += dur
            }
            for note in g.notes {
                events.append(TimedMidiEvent(
                    tick: max(0, onset),
                    event: .noteOn(
                        channel: channel,
                        pitch: note.pitch,
                        velocity: velocity
                    )
                ))
                events.append(TimedMidiEvent(
                    tick: max(0, onset + dur - 1),
                    event: .noteOff(
                        channel: channel, pitch: note.pitch, velocity: 0
                    )
                ))
            }
        }

        // 3. Main chord — onset shifted by stealFromHead, length
        //    shortened by stealFromHead + stealFromTail.
        let mainOnset = tick + stealFromHead
        let playedTicks = max(1, mainTicks - stealFromHead - stealFromTail)
        let gate = defaultArticulationGateTime(for: instrument)
        let gatedTicks = playedTicks * gate / 100
        let mainOff = mainOnset + gatedTicks - 1
        if let arpeggio = chord.arpeggio {
            // Keep arpeggio behaviour intact: same call as the
            // pre-grace path, just with the shifted onset / shortened
            // length. This preserves the existing arpeggio tests.
            let pairs = arpeggioNoteEvents(
                noteCount: chord.notes.count,
                chordTicks: playedTicks,
                stretch: arpeggio.timeStretch,
                tempoBps: tempoBps
            )
            let order = arpeggio.isAscending
                ? Array(0 ..< chord.notes.count)
                : Array((0 ..< chord.notes.count).reversed())
            for (i, noteIndex) in order.enumerated() {
                let note = chord.notes[noteIndex]
                let onTick = mainOnset + pairs[i].onOffset
                let offTick = mainOnset + pairs[i].offOffset
                emitNoteEventsForGrace(
                    note: note, channel: channel, velocity: velocity,
                    onTick: onTick, offTick: offTick, events: &events
                )
            }
        } else {
            for note in chord.notes {
                if let glissando = note.glissando, let endPitch = glissandoEndPitch {
                    renderGlissandoNote(
                        note: note, glissando: glissando, endPitch: endPitch,
                        startTick: mainOnset, durationTicks: playedTicks,
                        velocity: velocity, channel: channel,
                        currentKey: currentKey, events: &events
                    )
                } else {
                    emitNoteEventsForGrace(
                        note: note, channel: channel, velocity: velocity,
                        onTick: mainOnset, offTick: mainOff, events: &events
                    )
                }
            }
        }

        // 4. After-graces — share the tail slot the main gave up.
        var afterCursor = mainOnset + playedTicks
        for g in chord.graceNotesAfter {
            let dur = playbackTicks(
                for: g, mainTicks: mainTicks, division: division
            )
            for note in g.notes {
                events.append(TimedMidiEvent(
                    tick: afterCursor,
                    event: .noteOn(
                        channel: channel, pitch: note.pitch, velocity: velocity
                    )
                ))
                events.append(TimedMidiEvent(
                    tick: afterCursor + dur - 1,
                    event: .noteOff(
                        channel: channel, pitch: note.pitch, velocity: 0
                    )
                ))
            }
            afterCursor += dur
        }
    }

    /// Map of pitch → most recent noteOn tick on `channel`. Used by
    /// the prev-chord shortening pass to avoid pulling a noteOff in
    /// past its own noteOn.
    private static func collectPriorNoteOnTicks(
        in events: [TimedMidiEvent], channel: Int
    ) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for e in events {
            if case let .noteOn(ch, pitch, _) = e.event, ch == channel {
                map[pitch] = e.tick
            }
        }
        return map
    }

    /// Same tie-aware emit as `MidiRenderer.emitNoteEvents` (private
    /// in `+Voice.swift`). Re-implemented here to avoid widening
    /// access on the original.
    private static func emitNoteEventsForGrace(
        note: Note,
        channel: Int,
        velocity: Int,
        onTick: Int,
        offTick: Int,
        events: inout [TimedMidiEvent]
    ) {
        if note.tieBack == nil {
            events.append(TimedMidiEvent(
                tick: onTick,
                event: .noteOn(channel: channel, pitch: note.pitch, velocity: velocity)
            ))
        }
        if note.tieForward == nil {
            events.append(TimedMidiEvent(
                tick: offTick,
                event: .noteOff(channel: channel, pitch: note.pitch, velocity: 0)
            ))
        }
    }
```

- [ ] **Step 5: Run integration tests**

Run: `swift test --filter GraceMidiIntegrationTests`
Expected: PASS (4 cases).

- [ ] **Step 6: Run the full MIDI export suite for regression**

Run: `swift test --filter MidiExportTests`
Expected: PASS (12 cases, unchanged — none of the existing fixtures use graces).

- [ ] **Step 7: Lint**

Run: `swiftlint --quiet Sources/SheetMusicMIDI`
Expected: 0 warnings. (The new function legitimately exceeds 50 lines — keep the existing `// swiftlint:disable:next function_body_length` comment style if needed.)

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift Tests/SheetMusicTests/GraceNoteMidiTests.swift
git commit -m "feat(midi): render grace notes with time-stealing"
```

---

## Task 8: Layout — `LayoutElement.graceChord` case

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift`
- Test: `Tests/SheetMusicTests/GraceNoteLayoutTests.swift`

The layout case carries everything the renderer needs without holding a back-pointer to the parent chord (Score values stay self-contained).

- [ ] **Step 1: Create the test file**

Create `Tests/SheetMusicTests/GraceNoteLayoutTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutElement.graceChord")
struct GraceLayoutElementTests {
    @Test("Case stores hasSlash, mag, relativeX")
    func storesFields() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = LayoutElement.graceChord(
            notes: [],
            duration: .eighth,
            stem: .up,
            stemOrigin: .zero,
            relativeX: -10,
            hasSlash: true,
            mag: 0.6,
            voiceIndex: 0
        )
        guard case let .graceChord(_, _, _, _, relX, slash, mag, _) = element else {
            Issue.record("not graceChord"); return
        }
        #expect(relX == -10)
        #expect(slash == true)
        #expect(mag == 0.6)
    }
}
```

- [ ] **Step 2: Run to confirm compile failure**

Run: `swift test --filter GraceLayoutElementTests`
Expected: FAIL — "type 'LayoutElement' has no case 'graceChord'".

- [ ] **Step 3: Add the case**

In `Sources/SheetMusicLayout/Layout/LayoutElement.swift`, find `public enum LayoutElement: Sendable, Equatable {` (line 14) and add this case immediately after the existing `.chord(...)` case (around line 38):

```swift
    /// A grace note (or grace chord) drawn at reduced size next to
    /// its parent main chord. Carries a `relativeX` offset from the
    /// main notehead (negative for before-graces, positive for
    /// after-graces) so the renderer can position it without
    /// holding a reference to the parent.
    case graceChord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        relativeX: CGFloat,
        hasSlash: Bool,
        mag: CGFloat,
        voiceIndex: Int
    )
```

- [ ] **Step 4: Make the new case exhaustive in `+Translate.swift`**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift`, replace the catch-all:

```swift
        case .note, .marker, .jump, .measureNumber, .staffName,
             .spannerSegment, .tieArc:
            return element
```

with the grace-aware version (preserving the existing list and adding a `.graceChord` arm above it):

```swift
        case let .graceChord(
            notes, dur, stem, so, relX, slash, mag, vi
        ):
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    noteID: $0.noteID,
                    step: $0.step,
                    accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward,
                    tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando,
                    headType: $0.headType,
                    mirror: $0.mirror
                )
            }
            return .graceChord(
                notes: shiftedNotes,
                duration: dur,
                stem: stem,
                stemOrigin: shift(so),
                relativeX: relX,
                hasSlash: slash,
                mag: mag,
                voiceIndex: vi
            )
        case .note, .marker, .jump, .measureNumber, .staffName,
             .spannerSegment, .tieArc:
            return element
```

- [ ] **Step 5: Run the test**

Run: `swift test --filter GraceLayoutElementTests`
Expected: PASS.

- [ ] **Step 6: Build the package to confirm no other exhaustiveness sites broke**

Run: `swift build`
Expected: PASS. If a switch-on-`LayoutElement` site refuses to compile because it relied on an exhaustive close, fix that site by adding `case .graceChord: break` (or the right behaviour for that site) and note the file in the commit message.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutElement.swift Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift Tests/SheetMusicTests/GraceNoteLayoutTests.swift
git commit -m "feat(layout): add LayoutElement.graceChord case"
```

---

## Task 9: Layout — emit `.graceChord` from placement

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Extents.swift`
- Modify: `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`
- Test: `Tests/SheetMusicTests/GraceNoteLayoutTests.swift` (append)

The placement engine emits, for every main chord with graces, a `.graceChord` element per `GraceChord` *before* and *after* the chord's `.chord(...)` element so renderer order matches z-order. `relativeX` per before-grace = `-graceWidth × (n - i)`; per after-grace = `+graceWidth × (i + 1)`. `graceWidth = sp * 1.5` is a simple constant — wide enough for a 0.6× notehead + flag, narrow enough that 3 stacked graces still clear the previous chord (verified visually with `idea8.mscx` in Task 13).

- [ ] **Step 1: Add `graceNoteMag` to `ScoreViewOptions`**

In `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`, inside the `ScoreViewOptions` struct add a new field and init parameter (after `showBreakIndicators`):

```swift
    /// Visual scale factor applied to grace-note glyphs (notehead +
    /// stem + flag) relative to a main chord. MuseScore's
    /// `Sid::graceNoteMag` default is 0.7; we use 0.6 to stay
    /// closer to the historical "Petrucci" look used in Bravura.
    public var graceNoteMag: CGFloat
```

Update the `init`:

```swift
    public init(
        staffSize: CGFloat = 28,
        systemGap: CGFloat = 40,
        wrapToViewWidth: Bool = true,
        includeTitleFrame: Bool = true,
        breakPolicy: LayoutBreakPolicy = .honor,
        showBreakIndicators: Bool = true,
        graceNoteMag: CGFloat = 0.6
    ) {
        self.staffSize = staffSize
        self.systemGap = systemGap
        self.wrapToViewWidth = wrapToViewWidth
        self.includeTitleFrame = includeTitleFrame
        self.breakPolicy = breakPolicy
        self.showBreakIndicators = showBreakIndicators
        self.graceNoteMag = graceNoteMag
    }
```

- [ ] **Step 2: Add a static `graceWidth` helper**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Extents.swift`, append (still inside `extension LayoutEngine`, immediately after `noteheadHalfExtent`):

```swift
    /// Horizontal width budget for one grace note in measure-local
    /// units. Picked once-and-for-all at 1.5 sp — wide enough for a
    /// 0.6×-scaled notehead + flag, narrow enough that three graces
    /// can stack before bumping into the previous chord.
    static func graceWidth(sp: CGFloat) -> CGFloat {
        sp * 1.5
    }
```

- [ ] **Step 3: Write the failing test**

Append to `Tests/SheetMusicTests/GraceNoteLayoutTests.swift`:

```swift
@Suite("Grace placement")
@available(macOS 15.0, iOS 16.0, *)
struct GracePlacementTests {
    /// Build a score with a single chord that carries graces and
    /// run it through the layout engine. Returns the placed
    /// elements of measure 0.
    private func place(graces before: [GraceType]) -> [LayoutElement] {
        let mainNote = Note(pitch: 60, tpc: 14)
        let graceChords = before.map { gt in
            GraceChord(
                graceType: gt, duration: .eighth,
                notes: ChordNotes([Note(pitch: 62, tpc: 16)])
            )
        }
        let main = Chord(
            duration: .quarter, notes: ChordNotes([mainNote]),
            graceNotesBefore: graceChords
        )
        let measure = Measure(voices: [Voice(elements: [.chord(main)])])
        let staff = Staff(measures: [measure])
        let part = Part(instrument: Instrument(name: "piano"), staves: [staff])
        let score = Score(parts: [part])
        let doc = LayoutEngine.layout(
            score: score, options: ScoreViewOptions(), availableWidth: 800
        )
        return doc.systems.flatMap { $0.measures.flatMap(\.elements) }
    }

    @Test("Two before-graces appear before main chord in element order")
    func twoBefore() {
        let elements = place(graces: [.acciaccatura, .grace16])
        let graceIndices = elements.indices.filter {
            if case .graceChord = elements[$0] { return true }; return false
        }
        let mainIndex = elements.firstIndex(where: {
            if case .chord = $0 { return true }; return false
        })!
        #expect(graceIndices.count == 2)
        for gi in graceIndices { #expect(gi < mainIndex) }
    }

    @Test("acciaccatura sets hasSlash = true")
    func acciaccaturaSlash() {
        let elements = place(graces: [.acciaccatura])
        guard case let .graceChord(_, _, _, _, _, slash, _, _) = elements.first(where: {
            if case .graceChord = $0 { return true }; return false
        })! else { Issue.record("no grace"); return }
        #expect(slash == true)
    }

    @Test("Non-acciaccatura graces have hasSlash = false")
    func nonAcciaccaturaNoSlash() {
        let elements = place(graces: [.grace16])
        guard case let .graceChord(_, _, _, _, _, slash, _, _) = elements.first(where: {
            if case .graceChord = $0 { return true }; return false
        })! else { Issue.record("no grace"); return }
        #expect(slash == false)
    }
}
```

- [ ] **Step 4: Run to confirm it fails**

Run: `swift test --filter GracePlacementTests`
Expected: FAIL — placement currently emits no `.graceChord` elements.

- [ ] **Step 5: Emit graces from placement**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`, locate the chord arm of the inner switch (currently around line 430, `case let .chord(chord):`). Immediately AFTER the existing `out.append(.chord(...))` block (the 11-line block that ends with `voiceIndex: voiceIdx`), and BEFORE the `if let arp = chord.arpeggio` block, insert:

```swift
                    // Emit grace notes for this chord. Before-graces
                    // use negative `relativeX` so the renderer draws
                    // them to the left of the main notehead; after-
                    // graces use positive offsets to the right. Order
                    // in `out` is `[before-graces..., main, after-
                    // graces...]` so renderer z-order picks up
                    // naturally — graces never sit on top of a
                    // notehead they belong to. Stem-direction picks
                    // up from the grace's own pitch via
                    // `StemDirectionRule`. Voice index is inherited
                    // from the parent.
                    let graceW = LayoutEngine.graceWidth(sp: metrics.sp)
                    let mag = options.graceNoteMag
                    for (gIdx, g) in chord.graceNotesBefore.enumerated() {
                        let relX = -graceW * CGFloat(chord.graceNotesBefore.count - gIdx)
                        let layoutNotes = makeGraceLayoutNotes(
                            grace: g, atX: chordX + relX,
                            staffMidY: staffMidY, metrics: metrics,
                            currentClef: currentClef,
                            staffAddress: staffAddress,
                            measureIndex: measureIndex,
                            voiceIdx: voiceIdx,
                            voiceElemIdx: voiceElemIdx,
                            graceIdx: gIdx, isAfter: false,
                            drumLineMap: drumLineMap
                        )
                        let stem = StemDirectionRule.direction(
                            for: layoutNotes.map(\.step)
                        )
                        out.append(.graceChord(
                            notes: layoutNotes,
                            duration: g.duration,
                            stem: stem,
                            stemOrigin: CGPoint(x: chordX + relX, y: staffMidY),
                            relativeX: relX,
                            hasSlash: g.graceType == .acciaccatura,
                            mag: mag,
                            voiceIndex: voiceIdx
                        ))
                    }
                    for (gIdx, g) in chord.graceNotesAfter.enumerated() {
                        let relX = graceW * CGFloat(gIdx + 1)
                        let layoutNotes = makeGraceLayoutNotes(
                            grace: g, atX: chordX + relX,
                            staffMidY: staffMidY, metrics: metrics,
                            currentClef: currentClef,
                            staffAddress: staffAddress,
                            measureIndex: measureIndex,
                            voiceIdx: voiceIdx,
                            voiceElemIdx: voiceElemIdx,
                            graceIdx: gIdx, isAfter: true,
                            drumLineMap: drumLineMap
                        )
                        let stem = StemDirectionRule.direction(
                            for: layoutNotes.map(\.step)
                        )
                        out.append(.graceChord(
                            notes: layoutNotes,
                            duration: g.duration,
                            stem: stem,
                            stemOrigin: CGPoint(x: chordX + relX, y: staffMidY),
                            relativeX: relX,
                            hasSlash: false,
                            mag: mag,
                            voiceIndex: voiceIdx
                        ))
                    }
```

NOTE on the order: `out.append(.chord(...))` happens BEFORE we append before-graces here, which contradicts the comment above. To get `[before..., main, after...]`, MOVE the original `out.append(.chord(...))` call to a `let mainElement` binding, append the before-graces first, append `mainElement`, then append after-graces. Refactor like this:

Replace the existing chord append block:

```swift
                    voiceChordOutIndex[voiceElemIdx] = out.count
                    out.append(.chord(
                        notes: chordNotes,
                        duration: chord.duration,
                        stem: stem,
                        stemOrigin: CGPoint(x: chordX, y: staffMidY),
                        hasArpeggio: chord.arpeggio != nil,
                        arpeggioRawType: chord.arpeggio.flatMap(arpeggioSubtype),
                        isBeamed: false,
                        voiceIndex: voiceIdx
                    ))
```

with:

```swift
                    let mainElement: LayoutElement = .chord(
                        notes: chordNotes,
                        duration: chord.duration,
                        stem: stem,
                        stemOrigin: CGPoint(x: chordX, y: staffMidY),
                        hasArpeggio: chord.arpeggio != nil,
                        arpeggioRawType: chord.arpeggio.flatMap(arpeggioSubtype),
                        isBeamed: false,
                        voiceIndex: voiceIdx
                    )
                    let graceW = LayoutEngine.graceWidth(sp: metrics.sp)
                    let mag = options.graceNoteMag
                    for (gIdx, g) in chord.graceNotesBefore.enumerated() {
                        let relX = -graceW * CGFloat(chord.graceNotesBefore.count - gIdx)
                        let layoutNotes = makeGraceLayoutNotes(
                            grace: g, atX: chordX + relX,
                            staffMidY: staffMidY, metrics: metrics,
                            currentClef: currentClef,
                            staffAddress: staffAddress,
                            measureIndex: measureIndex,
                            voiceIdx: voiceIdx,
                            voiceElemIdx: voiceElemIdx,
                            graceIdx: gIdx, isAfter: false,
                            drumLineMap: drumLineMap
                        )
                        let stem = StemDirectionRule.direction(
                            for: layoutNotes.map(\.step)
                        )
                        out.append(.graceChord(
                            notes: layoutNotes,
                            duration: g.duration,
                            stem: stem,
                            stemOrigin: CGPoint(x: chordX + relX, y: staffMidY),
                            relativeX: relX,
                            hasSlash: g.graceType == .acciaccatura,
                            mag: mag,
                            voiceIndex: voiceIdx
                        ))
                    }
                    voiceChordOutIndex[voiceElemIdx] = out.count
                    out.append(mainElement)
                    for (gIdx, g) in chord.graceNotesAfter.enumerated() {
                        let relX = graceW * CGFloat(gIdx + 1)
                        let layoutNotes = makeGraceLayoutNotes(
                            grace: g, atX: chordX + relX,
                            staffMidY: staffMidY, metrics: metrics,
                            currentClef: currentClef,
                            staffAddress: staffAddress,
                            measureIndex: measureIndex,
                            voiceIdx: voiceIdx,
                            voiceElemIdx: voiceElemIdx,
                            graceIdx: gIdx, isAfter: true,
                            drumLineMap: drumLineMap
                        )
                        let stem = StemDirectionRule.direction(
                            for: layoutNotes.map(\.step)
                        )
                        out.append(.graceChord(
                            notes: layoutNotes,
                            duration: g.duration,
                            stem: stem,
                            stemOrigin: CGPoint(x: chordX + relX, y: staffMidY),
                            relativeX: relX,
                            hasSlash: false,
                            mag: mag,
                            voiceIndex: voiceIdx
                        ))
                    }
```

(The change keeps `voiceChordOutIndex[voiceElemIdx] = out.count` aimed at the main chord, not at the first before-grace — the tuplet labeller and tie pairing both look chord up by this index.)

- [ ] **Step 6: Add the `makeGraceLayoutNotes` helper**

Append a new file-private helper at the bottom of `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` (still inside `extension LayoutEngine`):

```swift
    // swiftlint:disable function_parameter_count
    /// Build `LayoutChordNote` values for a single `GraceChord`.
    /// Mirrors the inline notehead construction used for main chords
    /// but takes `graceIdx` / `isAfter` so synthesized `NoteID`s
    /// don't collide with the parent chord's notes — important for
    /// hit-testing and the chord-origin lookup.
    fileprivate static func makeGraceLayoutNotes(
        grace: GraceChord,
        atX x: CGFloat,
        staffMidY: CGFloat,
        metrics: StaffMetrics,
        currentClef: NotatedClef,
        staffAddress: StaffAddress,
        measureIndex: Int,
        voiceIdx: Int,
        voiceElemIdx: Int,
        graceIdx: Int,
        isAfter: Bool,
        drumLineMap: [Int: Int]?
    ) -> [LayoutChordNote] {
        // Grace NoteIDs reuse the parent's element index but encode
        // the grace position in `noteIndexInChord` so they stay
        // unique across the (parent, grace) cluster:
        //   before-grace #i  → 1000 + i*100 + noteIdx
        //   after-grace  #i  → 2000 + i*100 + noteIdx
        // Cap at 8 graces × 16 notes per grace — well above
        // anything seen in real scores.
        let base = (isAfter ? 2_000 : 1_000) + graceIdx * 100
        return grace.notes.enumerated().map { noteIdx, note in
            let step: Int
            if let drumLine = drumLineMap?[note.pitch] {
                step = 4 - drumLine
            } else {
                step = PitchStaffPosition.step(
                    midiPitch: note.pitch, tpc: note.tpc,
                    clef: currentClef
                ).step
            }
            let y = staffMidY - CGFloat(step) * metrics.sp / 2
            let id = NoteID(
                staff: staffAddress,
                measureIndex: measureIndex,
                voiceIndex: voiceIdx,
                elementIndex: voiceElemIdx,
                noteIndexInChord: base + noteIdx
            )
            return LayoutChordNote(
                noteID: id,
                step: step,
                accidental: note.accidental,
                origin: CGPoint(x: x, y: y),
                tieForward: nil, tieBack: nil,
                hasGlissando: false,
                headType: note.headType
            )
        }
    }
    // swiftlint:enable function_parameter_count
```

- [ ] **Step 7: Run the placement tests**

Run: `swift test --filter GracePlacementTests`
Expected: PASS (3 tests).

- [ ] **Step 8: Run all layout tests for regression**

Run: `swift test --filter "LayoutEngineTests|LayoutBreakTests|LayoutBracketTests|LayoutSystemEventColumnsTests|LayoutPartLabelClefTests|LayoutCacheTests"`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/SheetMusicLayout/Options/ScoreViewOptions.swift Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift Sources/SheetMusicLayout/Layout/LayoutEngine+Extents.swift Tests/SheetMusicTests/GraceNoteLayoutTests.swift
git commit -m "feat(layout): emit graceChord elements alongside parent chord"
```

---

## Task 10: Layout — reserve horizontal space for before-graces

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift`
- Test: `Tests/SheetMusicTests/GraceNoteLayoutTests.swift` (append)

`LayoutEngine+Spacing.swift` builds the per-tick `EventColumn` widths that drive measure stretching. Before-graces add `count × graceWidth` of left padding to the parent chord's column; after-graces add the same to the *next* chord's left padding (or to the trailing barline pad when last). Without this, a grace cluster collides with the previous notehead in tight measures.

The single weight per timed element is built around line 282-290 of `LayoutEngine+Spacing.swift`:

```swift
                    case let .chord(c) where !c.notes.isEmpty:
                        let nextLyrics = nextChordLyrics(
                            in: voice.elements, after: idx
                        )
                        let baseWeight = max(
                            durationWidth(c.duration, metrics: metrics),
                            lyricsPairWidth(
                                currentLyrics: c.lyrics,
                                nextLyrics: nextLyrics,
                                metrics: metrics
                            )
                        )
                        let w = max(baseWeight, pendingHarmonyWidth)
```

We widen `baseWeight` by the before-grace and after-grace budgets so the proportional spacer reserves room. Before-grace eats into THIS chord's column; after-grace into THIS chord's column too (the pre-existing `+0.5 sp gap` margin handles the gap to the next chord — there's no separate next-chord-leftpad term).

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/GraceNoteLayoutTests.swift`:

```swift
@Suite("Grace spacing")
@available(macOS 15.0, iOS 16.0, *)
struct GraceSpacingTests {
    @Test("Three before-graces push the main chord X to the right vs. zero graces")
    func extraSpacing() {
        func mainX(_ before: [GraceType]) -> CGFloat {
            let main = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                graceNotesBefore: before.map { gt in
                    GraceChord(graceType: gt, duration: .eighth,
                               notes: ChordNotes([Note(pitch: 62, tpc: 16)]))
                }
            )
            let measure = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter,
                             notes: ChordNotes([Note(pitch: 55, tpc: 13)]))),
                .chord(main),
            ])])
            let staff = Staff(measures: [measure])
            let part = Part(instrument: Instrument(name: "piano"), staves: [staff])
            let score = Score(parts: [part])
            let doc = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 800
            )
            let elements = doc.systems.flatMap { $0.measures.flatMap(\.elements) }
            // Find the second chord (pitch 60) — that's `main`.
            for el in elements {
                if case let .chord(notes, _, _, _, _, _, _, _) = el,
                   notes.first?.step == 0 // pitch 60 above middle C in treble
                {
                    return el.stemX
                }
            }
            return 0
        }
        let withGraces = mainX([.grace16, .grace16, .grace16])
        let noGraces = mainX([])
        #expect(withGraces > noGraces)
    }
}

// Local helper for the test above — mirrors `LayoutDocument`'s
// internal way of grabbing a chord's stem X.
@available(macOS 15.0, iOS 16.0, *)
extension LayoutElement {
    var stemX: CGFloat {
        if case let .chord(_, _, _, so, _, _, _, _) = self { return so.x }
        return 0
    }
}
```

- [ ] **Step 2: Run the test (will fail)**

Run: `swift test --filter GraceSpacingTests`
Expected: FAIL — without the budget the two main chords share the same proportional position regardless of graces.

- [ ] **Step 3: Widen `baseWeight` to include the grace budget**

Open `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift`. Replace the chord arm at lines 278-297 with the grace-aware version (only this arm — leave every other case alone):

```swift
                    case let .chord(c) where !c.notes.isEmpty:
                        let nextLyrics = nextChordLyrics(
                            in: voice.elements, after: idx
                        )
                        // Reserve column width for grace clusters
                        // attached to this chord. Both ends bake into
                        // THIS column's weight so neighbour chords —
                        // sharing the same proportional spacer — keep
                        // a clean gap from the grace glyphs.
                        let graceBudget = LayoutEngine.graceWidth(sp: metrics.sp)
                            * CGFloat(c.graceNotesBefore.count + c.graceNotesAfter.count)
                        let baseWeight = max(
                            durationWidth(c.duration, metrics: metrics) + graceBudget,
                            lyricsPairWidth(
                                currentLyrics: c.lyrics,
                                nextLyrics: nextLyrics,
                                metrics: metrics
                            )
                        )
                        let w = max(baseWeight, pendingHarmonyWidth)
                        pendingHarmonyWidth = 0
                        let end = tick + c.duration.ticks(division: division)
                        elements.append(TimedElement(
                            startTick: tick, endTick: end, weight: w
                        ))
                        allTicks.insert(tick)
                        tick = end
```

- [ ] **Step 4: Run the spacing test**

Run: `swift test --filter GraceSpacingTests`
Expected: PASS.

- [ ] **Step 5: Run all layout tests for regression**

Run: `swift test --filter "LayoutEngineTests|LayoutBreakTests|LayoutBracketTests|LayoutSystemEventColumnsTests|LayoutCacheTests|GracePlacementTests"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift Tests/SheetMusicTests/GraceNoteLayoutTests.swift
git commit -m "feat(layout): reserve horizontal space for grace clusters"
```

---

## Task 11: UI — `GraceChordRenderer` with Bravura slash

**Files:**
- Create: `Sources/SheetMusicUI/Rendering/GraceChordRenderer.swift`
- Modify: `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift`

The renderer reuses `NoteheadRenderer` / `StemRenderer` / `AccidentalRenderer` at a synthetic `mag * sp` scale. The acciaccatura slash is one extra glyph layered on top of the stem mid-point.

- [ ] **Step 1: Add the SMuFL codepoints**

In `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift`, find the `// Flags` section (around line 41) and add:

```swift
    // Grace-note slash glyphs (SMuFL `graceNoteSlash`)
    // Used for `acciaccatura` indication: one diagonal slash
    // through the stem. Up = U+E564, Down = U+E565.
    static let graceNoteSlashStemUp: Character = "\u{E564}"
    static let graceNoteSlashStemDown: Character = "\u{E565}"
```

- [ ] **Step 2: Create the renderer**

Create `Sources/SheetMusicUI/Rendering/GraceChordRenderer.swift`:

```swift
import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, iOS 16.0, *)
extension ScoreLayerBuilder {
    /// Draw a `LayoutElement.graceChord` by recursively reusing the
    /// main-chord renderers at a `mag`-scaled `StaffMetrics`.
    /// Acciaccatura adds a SMuFL slash glyph over the stem.
    // swiftlint:disable:next function_parameter_count
    static func drawGraceChord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        hasSlash: Bool,
        mag: CGFloat,
        base: CGPoint,
        metrics: StaffMetrics,
        height: CGFloat,
        context: inout BuildContext,
        into parent: CALayer
    ) {
        // Build a scaled `StaffMetrics` so notehead / stem / flag
        // widths follow `mag`. Every dimension on `StaffMetrics`
        // derives from `sp = staffSize/4`, so feeding `staffSize *
        // mag` shrinks every glyph proportionally. The grace's
        // y-positions (already in parent-staff coordinates from the
        // layout step) are passed through untouched, so the glyphs
        // sit on the parent staff — only the GLYPH sizes shrink.
        let scaled = StaffMetrics(staffSize: metrics.staffHeight * mag)
        drawChord(
            notes: notes, duration: duration, stem: stem,
            stemOrigin: stemOrigin, isBeamed: false,
            base: base, metrics: scaled, height: height,
            context: &context, into: parent
        )
        guard hasSlash else { return }
        let glyph = stem == .up
            ? SMuFLGlyph.graceNoteSlashStemUp
            : SMuFLGlyph.graceNoteSlashStemDown
        let glyphSize = scaled.sp * 4
        let bravura = CTFontCreateWithName(
            BravuraFont.familyName as CFString, glyphSize, nil
        )
        // Slash sits ~1.5 sp up the stem from the notehead end.
        let dy: CGFloat = stem == .up ? -scaled.sp * 1.5 : scaled.sp * 1.5
        let position = CGPoint(
            x: base.x + stemOrigin.x,
            y: base.y + stemOrigin.y + dy
        )
        if let layer = textLayer(
            text: String(glyph), at: position,
            size: glyphSize, italic: false,
            anchor: CGPoint(x: 0.5, y: 0.5),
            font: bravura,
            height: height
        ) {
            parent.addSublayer(layer)
        }
    }
}
```

- [ ] **Step 3: Dispatch from the element switch**

In `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift`, find the `.chord` arm (around line 56) and add immediately after it (still inside the `switch element` block):

```swift
        case let .graceChord(
            notes, dur, stem, so, _, slash, mag, _
        ):
            drawGraceChord(
                notes: notes, duration: dur, stem: stem,
                stemOrigin: so, hasSlash: slash, mag: mag,
                base: base, metrics: metrics, height: height,
                context: &context, into: parent
            )
```

- [ ] **Step 4: Build and run all tests**

Run: `swift build && swift test`
Expected: PASS — 100% green.

- [ ] **Step 5: Lint**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/GraceChordRenderer.swift Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift
git commit -m "feat(ui): render grace chords with SMuFL slash glyph"
```

---

## Task 12: Visual verification on the Mac sample app

**Files:**
- (none — verification only)

Open `SheetMusicExampleMac` in Xcode (the project mandated by `feedback_visual_verify_mac.md`). Load `~/Desktop/idea8.mscx` and confirm:

- [ ] **Step 1: Confirm Xcode session has the example app open**

Run: `mcp__xcode__XcodeListWindows` (load schema via ToolSearch first if needed).
Expected: at least one window referring to `SheetMusicExample` — if not, ask the user to open it before continuing.

- [ ] **Step 2: Build the macOS sample app**

Build the app via the IDE or `xcodebuild` for the Mac target.
Expected: build succeeds; no warnings about missing `LayoutElement` cases.

- [ ] **Step 3: Render `idea8.mscx` and inspect**

Run the macOS app, open `~/Desktop/idea8.mscx`. Hand control to the user; ask them to confirm:
- the previously-displaced bars look correct;
- acciaccaturas show a stem slash;
- before-graces sit to the LEFT of their parent notehead, after-graces to the RIGHT;
- subsequent main chords haven't shifted right of their tick column.

If any check fails, file a follow-up task **before** moving on.

- [ ] **Step 4: Commit a screenshot to the spec folder (optional)**

If the user wants a visual record:

```bash
git add docs/superpowers/specs/2026-05-07-grace-notes-screenshot.png
git commit -m "docs(spec): add grace-notes visual verification screenshot"
```

---

## Task 13: Round-trip MIDI test against MuseScore reference (P-fixture)

**Files:**
- Add: `Tests/SheetMusicTests/Resources/grace-notes.mscx`
- Add: `Tests/SheetMusicTests/Resources/grace-notes-ref.mid`
- Modify: `Tests/SheetMusicTests/MidiExportTests.swift`

This task is **blocked on the user supplying the fixture pair**. It runs the same semantic-equivalence comparison the existing 12 cases use. Spec §"Test fixtures" calls these out as pending.

- [ ] **Step 1: Confirm the fixture files exist**

Run: `ls Tests/SheetMusicTests/Resources/grace-notes*.{mscx,mid}`
Expected: both files present. If not, ask the user to export them from MuseScore (`File → Export → MIDI`) and place them under `Tests/SheetMusicTests/Resources/`. Do NOT proceed without them.

- [ ] **Step 2: Add the case to `MidiExportTests`**

Open `Tests/SheetMusicTests/MidiExportTests.swift`. Tests are NOT parametric — each fixture is its own `@Test` method that calls `assertExportMatchesReference(name:)`. Add a new method right next to the existing `voltaDynamic`:

```swift
    @Test func graceNotes() throws { try assertExportMatchesReference(name: "grace-notes") }
```

- [ ] **Step 3: Run the new case**

Run: `swift test --filter MidiExportTests`
Expected: PASS — including the new `grace-notes` case.

If it fails, the diff in the failure message will pinpoint which event drifts. The most likely culprits are:
- a borderline cap rule in `totalStealFromMainHead`/`Tail` (Task 6);
- a missing `note.tieBack`/`tieForward` propagation in `emitNoteEventsForGrace` (Task 7);
- an off-by-one in the `mainOff` tick (gate calculation in Task 7).

Investigate via `systematic-debugging` skill. Do NOT loosen the comparator.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/Resources/grace-notes.mscx Tests/SheetMusicTests/Resources/grace-notes-ref.mid Tests/SheetMusicTests/MidiExportTests.swift
git commit -m "test(midi): add grace-notes MuseScore-equivalence case"
```

---

## Final sweep

After all tasks land:

- [ ] Run full suite: `swift test` — 100% green.
- [ ] Run lint: `swiftlint --quiet Sources Tests` — 0 warnings.
- [ ] Run example app build: `cd Example && xcodegen generate && xcodebuild -project Example/SheetMusicExample.xcodeproj -scheme SheetMusicExample -destination 'platform=iOS Simulator,name=iPhone 17' build` — succeeds.
- [ ] Skim `git log --oneline main..HEAD` — every task produced exactly one commit, all messages match repo style (`feat(core)`, `feat(midi)`, `feat(layout)`, `feat(ui)`, `test(midi)`).

If a follow-up surface (auto-slur, beam between graces, grace velocities) needs filing, drop a one-line entry in `docs/incremental-layout-future.md` rather than expanding this plan.
