# Note Input Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add command-based score editing primitives in `SheetMusicCore` — commands that carry their own inverses, applied through a `ScoreEditor` that owns an undo/redo stack — plus a minimal macOS demo where the user toggles input mode and types letter keys (C/D/E/F/G/A/B) to drop a note onto a selected rest, with `⌘Z` / `⌘⇧Z` driven by `UndoManager` thinly delegating into the editor.

**Architecture:** Three layers, bottom-up. (1) `SheetMusicCore` gets an `EditCommand` protocol whose `apply(to:) throws -> any EditCommand` returns the inverse command. Concrete commands (`ReplaceVoiceElement`, `SetNotePitch`, `InputNote`) are pure value types and the only way mutations happen inside the library. They depend on a new `VoiceElementID` (4-tuple path) plus `Score` subscript that resolves it. (2) `ScoreEditor` (a `@MainActor` `final class`) owns `var score: Score`, an undo stack of inverse commands, a redo stack, and a single entry point `apply(_:)`. `undo()` / `redo()` move commands between the stacks. (3) The example mac app gets a `NoteInputController` that wraps the editor, calls `UndoManager.registerUndo(withTarget:)` after each apply so `⌘Z` lands in `editor.undo()`. A small key handler, gated on input mode + a single-rest selection, maps letter keys to an `InputNote` command.

**Tech Stack:** Swift Package Manager, Swift Testing (`import Testing`), `@testable import` for sub-libraries, SwiftUI (macOS 15+), AppKit `NSEvent.addLocalMonitorForEvents` for letter-key handling, Foundation `UndoManager` for system undo integration.

---

## Spec reference

No prior spec — design was agreed in conversation:
- Command-based mutation (commands as serializable values, each returns its inverse from `apply(to:)`).
- Undo stack lives in `SheetMusicCore.ScoreEditor`; the macOS app owns a thin bridge to `UndoManager`.
- Initial scope is one vertical slice: replace a selected rest with a single-note chord of the same duration via letter-key input. Multi-note chords, duration palettes, MIDI keyboard input are out of scope for this plan.

## File map

**New library files (`Sources/SheetMusicCore/Editing/`):**
- `VoiceElementID.swift` — value-based path to a `VoiceElement`; `Score` subscript getter + setter.
- `EditCommand.swift` — protocol, plus `SheetMusicError.invalidEdit(reason:)` extension.
- `ReplaceVoiceElement.swift` — primitive command: replace one voice element, inverse re-replaces the old one.
- `SetNotePitch.swift` — retunes an existing note's pitch + tpc; inverse restores prior values.
- `InputNote.swift` — convenience: replace `.rest(d)` with `.chord(d, [Note(pitch, tpc)])` of the same duration.
- `ScoreEditor.swift` — `@MainActor final class`; `apply` / `undo` / `redo` / `canUndo` / `canRedo`.

**Modified library files:**
- `Sources/SheetMusicCore/SheetMusicError.swift` — add `.invalidEdit(reason:)` case + `errorDescription`.

**New test files (`Tests/SheetMusicTests/EditingTests/`):**
- `VoiceElementIDTests.swift`
- `ReplaceVoiceElementTests.swift`
- `SetNotePitchTests.swift`
- `InputNoteTests.swift`
- `ScoreEditorTests.swift`
- `Helpers/EditingFixtures.swift` — small in-memory `Score` builder shared by editing tests (one staff, one measure, 4/4, four quarter rests).

**New Example files (macOS):**
- `Example/SheetMusicExample/macOS/NoteInputController.swift` — `@MainActor @Observable` class wrapping `ScoreEditor`, posting changes back to the SwiftUI score state and registering each apply with `UndoManager`.
- `Example/SheetMusicExample/macOS/NoteInputKeyMap.swift` — pure mapping `(KeyEquivalent, octave) -> (pitch: Int, tpc: Int)?` for the seven natural letters. Tested.
- `Tests/SheetMusicTests/NoteInputKeyMapTests.swift` — covers C..B in octave 4 and octave shift.

**Modified Example files (macOS):**
- `Example/SheetMusicExample/macOS/ContentViewMac.swift` — `@State` controller, toolbar toggle, extended `installKeyMonitor` to route letter keys when input mode is on.

## Conventions reminders

- Swift Testing: `import Testing`, `@Suite`, `@Test`, `#expect`, `#require`. Not XCTest.
- `@testable import SheetMusicCore` in editing tests. Re-exports through `SheetMusic` do not transitively grant testable access.
- File length cap (SwiftLint): 300 lines. The editor or commands should never approach it; split via `+Ext.swift` if they do.
- Idiomatic Swift naming. Commands are nouns/verbs (`InputNote`, `SetNotePitch`), not C++-style transliterations.
- All Score / editing types stay value types where possible. Only `ScoreEditor` is a class (mutable state owner with reference identity for `UndoManager`).
- Don't introduce GPL code; don't transliterate from MuseScore's `engraving::cmd` machinery — design fresh.

## Build / test commands

From the worktree root (`.worktrees/note-input-mode/`):

```bash
swift build
swift test                                              # full suite, expect 0 failures
swift test --filter ScoreEditorTests                    # focused
swift test --filter EditingTests                        # all command tests
```

App build (macOS) for visual verification:

```bash
cd Example && xcodegen generate
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExampleMac \
           -destination 'platform=macOS' build
```

Per project convention (memory `feedback_visual_verify_mac.md`): visual verification uses `SheetMusicExampleMac`, not the iOS simulator.

---

## Phase 1 — Voice element path & subscript

### Task 1: `VoiceElementID` value type + `Score` subscript

**Files:**
- Create: `Sources/SheetMusicCore/Editing/VoiceElementID.swift`
- Test: `Tests/SheetMusicTests/EditingTests/VoiceElementIDTests.swift`
- Test helper: `Tests/SheetMusicTests/EditingTests/Helpers/EditingFixtures.swift`

- [ ] **Step 1: Write the test fixture builder**

```swift
// Tests/SheetMusicTests/EditingTests/Helpers/EditingFixtures.swift
import SheetMusicCore

enum EditingFixtures {
    /// One part, one staff, one measure of four quarter rests in 4/4.
    /// The staff's only voice has 5 elements:
    ///   [0] timeSignature(4/4)
    ///   [1] rest(quarter)
    ///   [2] rest(quarter)
    ///   [3] rest(quarter)
    ///   [4] rest(quarter)
    static func fourQuarterRests() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(Rest(duration: .quarter)),
            .rest(Rest(duration: .quarter)),
            .rest(Rest(duration: .quarter)),
            .rest(Rest(duration: .quarter)),
        ])
        let measure = Measure(voices: [voice])
        let staff = StaffContent(id: 1, measures: [measure])
        return Score(division: 480, parts: [], staves: [staff])
    }
}
```

(If `TimeSignature.init(numerator:denominator:)` differs from this signature, look up the actual one in `Sources/SheetMusicCore/Score/TimeSignature.swift` and use it; the test only needs *some* element at index 0 so the rest indices match.)

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/SheetMusicTests/EditingTests/VoiceElementIDTests.swift
@testable import SheetMusicCore
import Testing

@Suite("VoiceElementID")
struct VoiceElementIDTests {
    @Test("Subscript getter resolves a valid path")
    func getterValid() {
        let score = EditingFixtures.fourQuarterRests()
        let id = VoiceElementID(staffIndex: 0, measureIndex: 0,
                                voiceIndex: 0, elementIndex: 1)
        guard case let .rest(rest) = score[id] else {
            Issue.record("expected a rest at index 1")
            return
        }
        #expect(rest.duration == .quarter)
    }

    @Test("Subscript getter returns nil for out-of-range path")
    func getterOutOfRange() {
        let score = EditingFixtures.fourQuarterRests()
        let id = VoiceElementID(staffIndex: 0, measureIndex: 0,
                                voiceIndex: 0, elementIndex: 99)
        #expect(score[id] == nil)
    }

    @Test("Subscript setter replaces the element at the given path")
    func setterReplaces() {
        var score = EditingFixtures.fourQuarterRests()
        let id = VoiceElementID(staffIndex: 0, measureIndex: 0,
                                voiceIndex: 0, elementIndex: 1)
        let chord = Chord(duration: .quarter,
                          notes: [Note(pitch: 60, tpc: 14)])
        score[id] = .chord(chord)
        guard case let .chord(c) = score[id] else {
            Issue.record("expected chord after set")
            return
        }
        #expect(c.notes.first?.pitch == 60)
    }

    @Test("RestID converts to VoiceElementID with same indices")
    func fromRestID() {
        let restID = RestID(staffIndex: 0, measureIndex: 0,
                            voiceIndex: 0, elementIndex: 1)
        let veID = VoiceElementID(restID)
        #expect(veID.staffIndex == 0)
        #expect(veID.measureIndex == 0)
        #expect(veID.voiceIndex == 0)
        #expect(veID.elementIndex == 1)
    }
}
```

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter VoiceElementIDTests`
Expected: FAIL — `VoiceElementID` is undefined.

- [ ] **Step 4: Implement `VoiceElementID` + subscript**

```swift
// Sources/SheetMusicCore/Editing/VoiceElementID.swift
import Foundation

/// Path-based identity of a `VoiceElement` inside a `Score`.
///
/// Walks `Score.staves[staff].measures[measure].voices[voice]
/// .elements[element]`. Unlike `RestID` / `NoteID`, this does NOT
/// constrain the element kind — any `VoiceElement` is addressable.
///
/// IDs are stable only for an immutable `Score`; mutating the
/// underlying score may invalidate existing IDs.
public struct VoiceElementID: Hashable, Sendable {
    public let staffIndex: Int
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elementIndex: Int

    public init(
        staffIndex: Int,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int
    ) {
        self.staffIndex = staffIndex
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elementIndex = elementIndex
    }

    public init(_ id: RestID) {
        self.init(
            staffIndex: id.staffIndex,
            measureIndex: id.measureIndex,
            voiceIndex: id.voiceIndex,
            elementIndex: id.elementIndex)
    }

    public init(_ id: NoteID) {
        self.init(
            staffIndex: id.staffIndex,
            measureIndex: id.measureIndex,
            voiceIndex: id.voiceIndex,
            elementIndex: id.elementIndex)
    }
}

extension Score {
    /// Resolves a `VoiceElementID` to its element, or `nil` if the
    /// path is out of range.
    public subscript(id: VoiceElementID) -> VoiceElement? {
        get {
            guard staves.indices.contains(id.staffIndex) else { return nil }
            let measures = staves[id.staffIndex].measures
            guard measures.indices.contains(id.measureIndex) else { return nil }
            let voices = measures[id.measureIndex].voices
            guard voices.indices.contains(id.voiceIndex) else { return nil }
            let elements = voices[id.voiceIndex].elements
            guard elements.indices.contains(id.elementIndex) else { return nil }
            return elements[id.elementIndex]
        }
        set {
            guard let newValue,
                  staves.indices.contains(id.staffIndex),
                  staves[id.staffIndex].measures.indices.contains(id.measureIndex),
                  staves[id.staffIndex].measures[id.measureIndex]
                      .voices.indices.contains(id.voiceIndex),
                  staves[id.staffIndex].measures[id.measureIndex]
                      .voices[id.voiceIndex].elements.indices
                          .contains(id.elementIndex)
            else { return }
            staves[id.staffIndex]
                .measures[id.measureIndex]
                .voices[id.voiceIndex]
                .elements[id.elementIndex] = newValue
        }
    }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `swift test --filter VoiceElementIDTests`
Expected: PASS, all 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/Editing/VoiceElementID.swift \
        Tests/SheetMusicTests/EditingTests/Helpers/EditingFixtures.swift \
        Tests/SheetMusicTests/EditingTests/VoiceElementIDTests.swift
git commit -m "core: VoiceElementID + Score subscript for editing"
```

---

## Phase 2 — EditCommand protocol & primitive command

### Task 2: `EditCommand` protocol + `SheetMusicError.invalidEdit`

**Files:**
- Create: `Sources/SheetMusicCore/Editing/EditCommand.swift`
- Modify: `Sources/SheetMusicCore/SheetMusicError.swift`

- [ ] **Step 1: Add the error case**

Edit `Sources/SheetMusicCore/SheetMusicError.swift`. Add `case invalidEdit(reason: String)` to the enum, after `.ioError`. Add a matching arm to `errorDescription`:

```swift
case let .invalidEdit(reason):
    return "Invalid edit: \(reason)"
```

- [ ] **Step 2: Create the protocol file**

```swift
// Sources/SheetMusicCore/Editing/EditCommand.swift
import Foundation

/// A single, undoable mutation applied to a `Score`.
///
/// Commands are pure values: applying a command produces its inverse,
/// which when applied restores the original state. `ScoreEditor`
/// keeps the inverses on an undo stack and replays them for `undo()`.
///
/// Concrete commands should:
///   * Validate that the target path is current; throw
///     `SheetMusicError.invalidEdit` otherwise.
///   * Capture enough state in the inverse to fully reverse the
///     change (old element, old pitch, etc).
///   * Be Sendable values — no class instances, no closures.
public protocol EditCommand: Sendable {
    /// Applies the edit to `score` in place. Returns the inverse
    /// command — applying the inverse to the post-edit `score`
    /// must restore the pre-edit state byte-for-byte.
    @discardableResult
    func apply(to score: inout Score) throws -> any EditCommand
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicCore/Editing/EditCommand.swift \
        Sources/SheetMusicCore/SheetMusicError.swift
git commit -m "core: EditCommand protocol + SheetMusicError.invalidEdit"
```

### Task 3: `ReplaceVoiceElement` command (TDD)

**Files:**
- Create: `Sources/SheetMusicCore/Editing/ReplaceVoiceElement.swift`
- Test: `Tests/SheetMusicTests/EditingTests/ReplaceVoiceElementTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SheetMusicTests/EditingTests/ReplaceVoiceElementTests.swift
@testable import SheetMusicCore
import Testing

@Suite("ReplaceVoiceElement")
struct ReplaceVoiceElementTests {
    private static let restAt1 = VoiceElementID(
        staffIndex: 0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
    private static let outOfRange = VoiceElementID(
        staffIndex: 0, measureIndex: 0, voiceIndex: 0, elementIndex: 99)

    @Test("apply replaces the element")
    func applyReplaces() throws {
        var score = EditingFixtures.fourQuarterRests()
        let chord = Chord(duration: .quarter,
                          notes: [Note(pitch: 60, tpc: 14)])
        let cmd = ReplaceVoiceElement(at: Self.restAt1, with: .chord(chord))
        _ = try cmd.apply(to: &score)
        guard case let .chord(c) = score[Self.restAt1] else {
            Issue.record("expected chord at index 1")
            return
        }
        #expect(c.notes.first?.pitch == 60)
    }

    @Test("inverse restores the original element")
    func inverseRestores() throws {
        var score = EditingFixtures.fourQuarterRests()
        let original = score
        let chord = Chord(duration: .quarter,
                          notes: [Note(pitch: 60, tpc: 14)])
        let cmd = ReplaceVoiceElement(at: Self.restAt1, with: .chord(chord))
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("apply throws invalidEdit for an out-of-range path")
    func applyOutOfRange() {
        var score = EditingFixtures.fourQuarterRests()
        let chord = Chord(duration: .quarter,
                          notes: [Note(pitch: 60, tpc: 14)])
        let cmd = ReplaceVoiceElement(
            at: Self.outOfRange, with: .chord(chord))
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ReplaceVoiceElementTests`
Expected: FAIL — `ReplaceVoiceElement` undefined.

- [ ] **Step 3: Implement the command**

```swift
// Sources/SheetMusicCore/Editing/ReplaceVoiceElement.swift
import Foundation

/// Replaces the `VoiceElement` at `location` with `element`.
///
/// The most primitive editing command: every other command in this
/// library could be expressed in terms of one or more of these.
public struct ReplaceVoiceElement: EditCommand {
    public let location: VoiceElementID
    public let element: VoiceElement

    public init(at location: VoiceElementID, with element: VoiceElement) {
        self.location = location
        self.element = element
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let old = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "ReplaceVoiceElement: no element at \(location)")
        }
        score[location] = element
        return ReplaceVoiceElement(at: location, with: old)
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ReplaceVoiceElementTests`
Expected: PASS, all 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Editing/ReplaceVoiceElement.swift \
        Tests/SheetMusicTests/EditingTests/ReplaceVoiceElementTests.swift
git commit -m "core: ReplaceVoiceElement command + inverse round-trip"
```

### Task 4: `SetNotePitch` command (TDD)

**Files:**
- Create: `Sources/SheetMusicCore/Editing/SetNotePitch.swift`
- Test: `Tests/SheetMusicTests/EditingTests/SetNotePitchTests.swift`

- [ ] **Step 1: Extend fixtures with a chord-bearing score**

Append to `Tests/SheetMusicTests/EditingTests/Helpers/EditingFixtures.swift`:

```swift
extension EditingFixtures {
    /// Same shape as `fourQuarterRests` but element index 1 is a
    /// quarter chord on C4 (pitch 60, tpc 14) instead of a rest.
    static func chordAtIndex1() -> Score {
        var score = fourQuarterRests()
        let chord = Chord(duration: .quarter,
                          notes: [Note(pitch: 60, tpc: 14)])
        let id = VoiceElementID(staffIndex: 0, measureIndex: 0,
                                voiceIndex: 0, elementIndex: 1)
        score[id] = .chord(chord)
        return score
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/SheetMusicTests/EditingTests/SetNotePitchTests.swift
@testable import SheetMusicCore
import Testing

@Suite("SetNotePitch")
struct SetNotePitchTests {
    private static let c4 = NoteID(
        staffIndex: 0, measureIndex: 0, voiceIndex: 0,
        elementIndex: 1, noteIndexInChord: 0)

    @Test("apply changes pitch and tpc")
    func applyChanges() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = SetNotePitch(at: Self.c4, pitch: 62, tpc: 16) // D4
        _ = try cmd.apply(to: &score)
        let note = try #require(score[Self.c4])
        #expect(note.pitch == 62)
        #expect(note.tpc == 16)
    }

    @Test("inverse restores prior pitch and tpc")
    func inverseRestores() throws {
        var score = EditingFixtures.chordAtIndex1()
        let original = score
        let cmd = SetNotePitch(at: Self.c4, pitch: 62, tpc: 16)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("apply throws when the path doesn't resolve to a note")
    func applyMissing() {
        var score = EditingFixtures.fourQuarterRests() // index 1 is a rest
        let cmd = SetNotePitch(at: Self.c4, pitch: 62, tpc: 16)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
```

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter SetNotePitchTests`
Expected: FAIL — `SetNotePitch` undefined.

- [ ] **Step 4: Implement the command**

```swift
// Sources/SheetMusicCore/Editing/SetNotePitch.swift
import Foundation

/// Retunes a note (changes its MIDI `pitch` and `tpc`) without
/// affecting its accidental, ties, or other notehead metadata.
///
/// Used for arrow-key transpose and for replacing one note within a
/// chord. The inverse is another `SetNotePitch` carrying the old
/// values.
public struct SetNotePitch: EditCommand {
    public let location: NoteID
    public let pitch: Int
    public let tpc: Int

    public init(at location: NoteID, pitch: Int, tpc: Int) {
        self.location = location
        self.pitch = pitch
        self.tpc = tpc
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let oldNote = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetNotePitch: no note at \(location)")
        }
        let veID = VoiceElementID(location)
        guard case var .chord(chord) = score[veID] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetNotePitch: element at \(veID) is not a chord")
        }
        var note = chord.notes[location.noteIndexInChord]
        note.pitch = pitch
        note.tpc = tpc
        chord.notes[location.noteIndexInChord] = note
        score[veID] = .chord(chord)
        return SetNotePitch(at: location,
                            pitch: oldNote.pitch,
                            tpc: oldNote.tpc)
    }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `swift test --filter SetNotePitchTests`
Expected: PASS, all 3 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/Editing/SetNotePitch.swift \
        Tests/SheetMusicTests/EditingTests/Helpers/EditingFixtures.swift \
        Tests/SheetMusicTests/EditingTests/SetNotePitchTests.swift
git commit -m "core: SetNotePitch command + inverse round-trip"
```

### Task 5: `InputNote` command (TDD)

**Files:**
- Create: `Sources/SheetMusicCore/Editing/InputNote.swift`
- Test: `Tests/SheetMusicTests/EditingTests/InputNoteTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SheetMusicTests/EditingTests/InputNoteTests.swift
@testable import SheetMusicCore
import Testing

@Suite("InputNote")
struct InputNoteTests {
    private static let restAt1 = RestID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1)

    @Test("apply replaces the rest with a single-note chord at the same duration")
    func applyReplacesRest() throws {
        var score = EditingFixtures.fourQuarterRests()
        let cmd = InputNote(at: Self.restAt1, pitch: 60, tpc: 14) // C4
        _ = try cmd.apply(to: &score)
        let veID = VoiceElementID(Self.restAt1)
        guard case let .chord(chord) = score[veID] else {
            Issue.record("expected chord")
            return
        }
        #expect(chord.duration == .quarter)
        #expect(chord.notes.count == 1)
        #expect(chord.notes[0].pitch == 60)
        #expect(chord.notes[0].tpc == 14)
    }

    @Test("inverse restores the original rest")
    func inverseRestoresRest() throws {
        var score = EditingFixtures.fourQuarterRests()
        let original = score
        let cmd = InputNote(at: Self.restAt1, pitch: 60, tpc: 14)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("apply throws when target is not a rest")
    func applyOnChord() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = InputNote(at: Self.restAt1, pitch: 62, tpc: 16)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter InputNoteTests`
Expected: FAIL — `InputNote` undefined.

- [ ] **Step 3: Implement the command**

```swift
// Sources/SheetMusicCore/Editing/InputNote.swift
import Foundation

/// Replaces a rest with a single-note chord of the same duration.
///
/// The simplest "drop a note" operation: target a rest, supply pitch
/// + tpc, and the command builds a fresh chord whose `duration`
/// matches the rest. The inverse re-installs the rest.
public struct InputNote: EditCommand {
    public let location: RestID
    public let pitch: Int
    public let tpc: Int

    public init(at location: RestID, pitch: Int, tpc: Int) {
        self.location = location
        self.pitch = pitch
        self.tpc = tpc
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let rest = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "InputNote: no rest at \(location)")
        }
        let chord = Chord(
            duration: rest.duration,
            notes: [Note(pitch: pitch, tpc: tpc)])
        let veID = VoiceElementID(location)
        score[veID] = .chord(chord)
        return ReplaceVoiceElement(at: veID, with: .rest(rest))
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter InputNoteTests`
Expected: PASS, all 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Editing/InputNote.swift \
        Tests/SheetMusicTests/EditingTests/InputNoteTests.swift
git commit -m "core: InputNote convenience command (rest -> single-note chord)"
```

---

## Phase 3 — ScoreEditor

### Task 6: `ScoreEditor` with `apply` / `undo` / `redo` (TDD)

**Files:**
- Create: `Sources/SheetMusicCore/Editing/ScoreEditor.swift`
- Test: `Tests/SheetMusicTests/EditingTests/ScoreEditorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SheetMusicTests/EditingTests/ScoreEditorTests.swift
@testable import SheetMusicCore
import Testing

@MainActor
@Suite("ScoreEditor")
struct ScoreEditorTests {
    private static let restAt1 = RestID(
        staffIndex: 0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

    @Test("apply mutates the score and enables undo")
    func applyEnablesUndo() throws {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests())
        #expect(editor.canUndo == false)
        try editor.apply(InputNote(
            at: Self.restAt1, pitch: 60, tpc: 14))
        #expect(editor.canUndo == true)
        #expect(editor.canRedo == false)
        let veID = VoiceElementID(Self.restAt1)
        guard case .chord = editor.score[veID] else {
            Issue.record("expected chord after apply")
            return
        }
    }

    @Test("undo restores prior state and enables redo")
    func undoRestores() throws {
        let original = EditingFixtures.fourQuarterRests()
        let editor = ScoreEditor(score: original)
        try editor.apply(InputNote(
            at: Self.restAt1, pitch: 60, tpc: 14))
        try editor.undo()
        #expect(editor.score == original)
        #expect(editor.canUndo == false)
        #expect(editor.canRedo == true)
    }

    @Test("redo replays the undone command")
    func redoReplays() throws {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests())
        try editor.apply(InputNote(
            at: Self.restAt1, pitch: 60, tpc: 14))
        let postApply = editor.score
        try editor.undo()
        try editor.redo()
        #expect(editor.score == postApply)
        #expect(editor.canUndo == true)
        #expect(editor.canRedo == false)
    }

    @Test("a fresh apply clears the redo stack")
    func freshApplyClearsRedo() throws {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests())
        try editor.apply(InputNote(
            at: Self.restAt1, pitch: 60, tpc: 14))
        try editor.undo()
        #expect(editor.canRedo == true)
        try editor.apply(InputNote(
            at: Self.restAt1, pitch: 62, tpc: 16))
        #expect(editor.canRedo == false)
    }

    @Test("undo with empty stack throws")
    func undoEmptyThrows() {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests())
        #expect(throws: SheetMusicError.self) {
            try editor.undo()
        }
    }

    @Test("redo with empty stack throws")
    func redoEmptyThrows() {
        let editor = ScoreEditor(
            score: EditingFixtures.fourQuarterRests())
        #expect(throws: SheetMusicError.self) {
            try editor.redo()
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ScoreEditorTests`
Expected: FAIL — `ScoreEditor` undefined.

- [ ] **Step 3: Implement `ScoreEditor`**

```swift
// Sources/SheetMusicCore/Editing/ScoreEditor.swift
import Foundation

/// Owns a mutable `Score` plus undo/redo stacks of inverse commands.
///
/// All mutations to the score must go through `apply(_:)`. Each apply
/// pushes the inverse onto the undo stack; `undo()` pops it, applies
/// it, and moves the *new* inverse onto the redo stack; `redo()` does
/// the symmetric move back.
///
/// `ScoreEditor` is `@MainActor` and a `final class` so a host app
/// can keep a stable reference to register with `UndoManager`.
@MainActor
public final class ScoreEditor {
    public private(set) var score: Score
    private var undoStack: [any EditCommand] = []
    private var redoStack: [any EditCommand] = []

    public init(score: Score) {
        self.score = score
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Applies `command`, pushes its inverse onto the undo stack,
    /// and clears the redo stack (a fresh edit invalidates redo).
    public func apply(_ command: any EditCommand) throws {
        let inverse = try command.apply(to: &score)
        undoStack.append(inverse)
        redoStack.removeAll()
    }

    /// Pops the most recent inverse off the undo stack and applies
    /// it, pushing *its* inverse onto the redo stack.
    public func undo() throws {
        guard let inverse = undoStack.popLast() else {
            throw SheetMusicError.invalidEdit(reason: "undo: empty stack")
        }
        let redo = try inverse.apply(to: &score)
        redoStack.append(redo)
    }

    /// Symmetric counterpart of `undo()`.
    public func redo() throws {
        guard let command = redoStack.popLast() else {
            throw SheetMusicError.invalidEdit(reason: "redo: empty stack")
        }
        let inverse = try command.apply(to: &score)
        undoStack.append(inverse)
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ScoreEditorTests`
Expected: PASS, all 6 tests.

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `swift test`
Expected: PASS, baseline 235 + new editing tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/Editing/ScoreEditor.swift \
        Tests/SheetMusicTests/EditingTests/ScoreEditorTests.swift
git commit -m "core: ScoreEditor with undo/redo stacks"
```

---

## Phase 4 — macOS Example app integration

### Task 7: `NoteInputKeyMap` (TDD)

**Files:**
- Create: `Example/SheetMusicExample/macOS/NoteInputKeyMap.swift`
- Test: `Tests/SheetMusicTests/NoteInputKeyMapTests.swift`

`NoteInputKeyMap` is pure logic, so it lives in the example sources but its mapping is unit-testable. We'll add it as part of the example target only — the test target already includes Example sources via the test-target dependency on the package. If that's not the case, we'll instead inline the mapping into the controller and test it through the controller. Confirm during Step 1.

- [ ] **Step 1: Confirm test reachability for example sources**

Run:

```bash
grep -n "Example" Package.swift
```

Expected: example sources are NOT compiled by `swift test` (Example is its own xcodeproj generated via xcodegen). That means the keymap file must live somewhere `swift test` can reach.

**Decision (record in this plan as we execute):** put `NoteInputKeyMap` in `Sources/SheetMusicCore/Editing/NoteInputKeyMap.swift` instead — it's pure pitch-class logic, useful to any future input UI, and lives in a layer the tests can import. Update the file map accordingly.

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/SheetMusicTests/EditingTests/NoteInputKeyMapTests.swift
@testable import SheetMusicCore
import Testing

@Suite("NoteInputKeyMap")
struct NoteInputKeyMapTests {
    @Test("Letter C in octave 4 maps to MIDI 60, TPC 14")
    func cFour() {
        let r = NoteInputKeyMap.pitch(forLetter: "c", octave: 4)
        #expect(r?.pitch == 60)
        #expect(r?.tpc == 14)
    }

    @Test("Letter G in octave 4 maps to MIDI 67, TPC 15")
    func gFour() {
        let r = NoteInputKeyMap.pitch(forLetter: "g", octave: 4)
        #expect(r?.pitch == 67)
        #expect(r?.tpc == 15)
    }

    @Test("Letter B in octave 5 maps to MIDI 83, TPC 19")
    func bFive() {
        let r = NoteInputKeyMap.pitch(forLetter: "b", octave: 5)
        #expect(r?.pitch == 83)
        #expect(r?.tpc == 19)
    }

    @Test("Non-letter key returns nil")
    func nonLetter() {
        #expect(NoteInputKeyMap.pitch(forLetter: "x", octave: 4) == nil)
        #expect(NoteInputKeyMap.pitch(forLetter: "1", octave: 4) == nil)
    }

    @Test("Uppercase letter is accepted")
    func uppercase() {
        let r = NoteInputKeyMap.pitch(forLetter: "C", octave: 4)
        #expect(r?.pitch == 60)
    }
}
```

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter NoteInputKeyMapTests`
Expected: FAIL — `NoteInputKeyMap` undefined.

- [ ] **Step 4: Implement the keymap**

```swift
// Sources/SheetMusicCore/Editing/NoteInputKeyMap.swift
import Foundation

/// Maps a keyboard letter (C..B) and an octave to the `(pitch, tpc)`
/// pair used by `Note`.
///
/// The TPC choice is the *natural* spelling — F=13, C=14, G=15,
/// D=16, A=17, E=18, B=19. Sharps / flats are out of scope for the
/// initial input slice.
public enum NoteInputKeyMap {
    /// Returns the natural-spelling `(pitch, tpc)` for `letter` in
    /// `octave`, where octave 4 contains middle C (MIDI 60). Returns
    /// `nil` if `letter` is not one of `c d e f g a b` (case
    /// insensitive).
    public static func pitch(
        forLetter letter: Character, octave: Int
    ) -> (pitch: Int, tpc: Int)? {
        let lower = Character(letter.lowercased())
        // Offsets from C in the chromatic scale.
        let pitchOffset: Int
        let tpc: Int
        switch lower {
        case "c": pitchOffset = 0;  tpc = 14
        case "d": pitchOffset = 2;  tpc = 16
        case "e": pitchOffset = 4;  tpc = 18
        case "f": pitchOffset = 5;  tpc = 13
        case "g": pitchOffset = 7;  tpc = 15
        case "a": pitchOffset = 9;  tpc = 17
        case "b": pitchOffset = 11; tpc = 19
        default: return nil
        }
        // MIDI note 0 is C(-1); octave 4 contains MIDI 60.
        let pitch = (octave + 1) * 12 + pitchOffset
        return (pitch, tpc)
    }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `swift test --filter NoteInputKeyMapTests`
Expected: PASS, all 5 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/Editing/NoteInputKeyMap.swift \
        Tests/SheetMusicTests/EditingTests/NoteInputKeyMapTests.swift
git commit -m "core: NoteInputKeyMap (letter + octave -> pitch, tpc)"
```

### Task 8: `NoteInputController` (macOS) — `ScoreEditor` + `UndoManager` bridge

**Files:**
- Create: `Example/SheetMusicExample/macOS/NoteInputController.swift`

This is UI-shaped code; we don't unit-test it. The architectural test is that it leans entirely on `ScoreEditor` for state.

- [ ] **Step 1: Implement the controller**

```swift
// Example/SheetMusicExample/macOS/NoteInputController.swift
#if os(macOS)
import AppKit
import SheetMusicCore
import SheetMusicUI

/// Wraps `ScoreEditor` and bridges to the host's `UndoManager`.
///
/// SwiftUI hands us an `UndoManager?` from the environment; on each
/// successful `apply`, we register an undo target with the manager
/// so that `⌘Z` reaches `editor.undo()` (and the manager's redo
/// stack reaches `editor.redo()`).
@MainActor
@Observable
final class NoteInputController {
    private(set) var editor: ScoreEditor
    /// Bumped on every applied / undone / redone edit so SwiftUI
    /// `.task(id:)` observers downstream of `score` rebuild their
    /// derived state (LayoutDocument, etc).
    private(set) var version = UUID()
    /// Whether the toolbar input toggle is on. The key handler only
    /// routes letter keys when this is true.
    var isInputModeOn = false
    /// Octave used by the next letter-key input. 4 = middle-C octave.
    var inputOctave = 4

    var score: Score { editor.score }

    init(score: Score) {
        self.editor = ScoreEditor(score: score)
    }

    /// Replaces the editor's score (e.g. after loading a new file).
    /// Drops undo history.
    func reset(score: Score) {
        editor = ScoreEditor(score: score)
        version = UUID()
    }

    /// Applies a command and registers undo with `manager`. The
    /// registration is recursive: when the manager replays our undo
    /// closure, that closure also calls `registerUndo` on itself so
    /// the redo path stays linked.
    func apply(
        _ command: any EditCommand,
        undoManager manager: UndoManager?
    ) throws {
        try editor.apply(command)
        version = UUID()
        registerUndo(with: manager)
    }

    private func registerUndo(with manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { target in
            do {
                try target.editor.undo()
                target.version = UUID()
                target.registerRedo(with: manager)
            } catch {
                NSLog("NoteInputController.undo failed: \(error)")
            }
        }
    }

    private func registerRedo(with manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { target in
            do {
                try target.editor.redo()
                target.version = UUID()
                target.registerUndo(with: manager)
            } catch {
                NSLog("NoteInputController.redo failed: \(error)")
            }
        }
    }
}
#endif
```

- [ ] **Step 2: Build to verify it compiles inside the example target**

Run:

```bash
cd Example && xcodegen generate && cd ..
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExampleMac \
           -destination 'platform=macOS' \
           build 2>&1 | tail -8
```

Expected: build succeeded. (If swiftlint reports warnings about file length we're well under 300.)

- [ ] **Step 3: Commit**

```bash
git add Example/SheetMusicExample/macOS/NoteInputController.swift
git commit -m "example(macOS): NoteInputController bridging ScoreEditor and UndoManager"
```

### Task 9: Wire into `ContentViewMac`

**Files:**
- Modify: `Example/SheetMusicExample/macOS/ContentViewMac.swift`

We need:
1. A `@State` `NoteInputController` initialised once a score loads.
2. A toolbar toggle for `isInputModeOn`.
3. Read `\.undoManager` from the SwiftUI environment.
4. Extend `installKeyMonitor` so when `isInputModeOn` is true and the
   selection is `.single(.rest(id))`, letter keys C..B fire an
   `InputNote` command via the controller; arrow keys ↑/↓ adjust
   `inputOctave`. Spacebar still goes to playback toggle, ahead of
   the input check, so it never gets shadowed.

- [ ] **Step 1: Add controller state + environment hook**

In `ContentViewMac.swift`, after the existing `@StateObject private var playbackEngine` declaration, add:

```swift
/// Edit-mode controller. Lives across score reloads — `reset(score:)`
/// is called from `adoptLoadedScore`.
@State private var inputController: NoteInputController?
@Environment(\.undoManager) private var undoManager
```

In the score-load path (search for `adoptLoadedScore` or where the loaded score is assigned to `score`), add right after the `score = loaded` line:

```swift
if let inputController {
    inputController.reset(score: loaded)
} else {
    inputController = NoteInputController(score: loaded)
}
```

- [ ] **Step 2: Wire the toolbar toggle**

Find the `.toolbar { ... }` block in `ContentViewMac.body`. Add (after the existing toolbar items, before the closing `}` of `.toolbar`):

```swift
ToolbarItem {
    Toggle(isOn: Binding(
        get: { inputController?.isInputModeOn ?? false },
        set: { inputController?.isInputModeOn = $0 }
    )) {
        Label("Input Mode", systemImage: "pencil.tip")
    }
    .disabled(inputController == nil)
}
```

- [ ] **Step 3: Extend `installKeyMonitor`**

Replace the body of the `NSEvent.addLocalMonitorForEvents` closure inside `installKeyMonitor` with the keyboard router below. The spacebar branch stays first (so input mode never shadows playback toggle).

```swift
keyMonitor = NSEvent.addLocalMonitorForEvents(
    matching: .keyDown
) { event in
    if event.keyCode == 49 && !event.isARepeat {
        togglePlayback()
        return nil
    }
    if let controller = inputController, controller.isInputModeOn {
        if let consumed = handleInputModeKey(event, controller: controller) {
            return consumed ? nil : event
        }
    }
    return event
}
```

Then add the helper method on `ContentViewMac` (place near `installKeyMonitor`):

```swift
/// Returns nil if the key wasn't relevant to input mode (caller
/// passes the event through). Returns true if it was consumed,
/// false if it was relevant-but-rejected (also pass through).
private func handleInputModeKey(
    _ event: NSEvent,
    controller: NoteInputController
) -> Bool? {
    // Octave shift via arrow keys (no modifiers, no auto-repeat).
    if !event.isARepeat,
       event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
        switch event.keyCode {
        case 126: // up arrow
            controller.inputOctave = min(8, controller.inputOctave + 1)
            return true
        case 125: // down arrow
            controller.inputOctave = max(0, controller.inputOctave - 1)
            return true
        default:
            break
        }
    }
    // Letter keys → InputNote on the currently selected rest.
    guard let chars = event.charactersIgnoringModifiers,
          let letter = chars.first,
          let mapped = NoteInputKeyMap.pitch(
              forLetter: letter,
              octave: controller.inputOctave)
    else {
        return nil
    }
    guard case let .single(.rest(restID)) = selection else {
        return false
    }
    do {
        try controller.apply(
            InputNote(at: restID, pitch: mapped.pitch, tpc: mapped.tpc),
            undoManager: undoManager)
        // After successful insertion, the rest is gone — selecting
        // the freshly-inserted note keeps the user oriented.
        let noteID = NoteID(
            staffIndex: restID.staffIndex,
            measureIndex: restID.measureIndex,
            voiceIndex: restID.voiceIndex,
            elementIndex: restID.elementIndex,
            noteIndexInChord: 0)
        selection = .single(.note(noteID))
        // Bump the SwiftUI score state so layout rebuilds.
        score = controller.score
        scoreVersion = UUID()
        return true
    } catch {
        errorMessage = error.localizedDescription
        return true
    }
}
```

- [ ] **Step 4: Build the macOS example**

```bash
cd Example && xcodegen generate && cd ..
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExampleMac \
           -destination 'platform=macOS' \
           build 2>&1 | tail -8
```

Expected: build succeeded.

- [ ] **Step 5: Visual verification (per `feedback_visual_verify_mac.md`)**

Run the app, load a score, click on a rest, toggle the input-mode pencil, type letter keys. Verify:
- Each letter swaps the rest for a notehead at the chosen pitch.
- ⌘Z removes the just-inserted note (reverts to the rest).
- ⌘⇧Z re-inserts.
- Arrow ↑ / ↓ shift the octave for subsequent inputs.
- Spacebar still toggles playback (input mode does not shadow it).

Record any UI gaps in a follow-up note rather than expanding this slice.

- [ ] **Step 6: Commit**

```bash
git add Example/SheetMusicExample/macOS/ContentViewMac.swift
git commit -m "example(macOS): wire input mode toggle + letter-key note input"
```

---

## Self-review checklist

- [ ] Each command's `apply(to:)` returns the inverse — round-trip tested.
- [ ] `ScoreEditor.apply` clears the redo stack — covered by `freshApplyClearsRedo`.
- [ ] `undo` / `redo` on empty stacks throw — covered.
- [ ] `NoteInputController` exposes mutation only through `apply`, never letting callers reach `editor.undo()` directly except through the `UndoManager` registration closure.
- [ ] Letter-key handling sits behind the `isInputModeOn` gate AND requires `.single(.rest)` selection.
- [ ] Spacebar shortcut is checked *before* input-mode routing.
- [ ] `NoteInputKeyMap` lives in `SheetMusicCore` (test-reachable) rather than the example target.
- [ ] No file exceeds 300 lines (SwiftLint cap).

## Out of scope (intentionally)

- Multi-note chord input (adding a second note to an existing chord).
- Duration palette / dotted notes / tuplets (caller can build any `Chord` and use `ReplaceVoiceElement` directly, but the example UI only handles "match the rest's duration").
- MIDI keyboard input.
- Cursor advancement after insert (the user must click the next rest themselves).
- iOS variant of the input UI.
- Persisting the edited score back to disk.

These can each become their own plan.
