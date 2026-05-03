# Part / Staff Type-Safety Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nest `Staff` under `Part`, unify `StaffDeclaration` + `StaffContent` into a single `Staff` type, replace flat `staffIndex: Int` IDs with path-based `StaffAddress`. This removes the implicit positional pairing that has caused `LayoutEngine` to misalign part labels and clefs in scores with multi-staff parts (Piano).

**Architecture:** Single-branch breaking change (private repo, no compat shims). Type signatures change first; the compiler then guides the migration. MSCX decoder rebuilt around mscx `<Staff id="N">` IDs with id-less fallback (single-part / single-staff scores). One new test-only MIT fixture `multiPartMixedStaves.mscx` exercises the bug case (Vln, Vln, Piano, Vc).

**Tech Stack:** Swift 5.10 / SPM, Swift Testing (`@Test`, `#expect`), SwiftLint.

**Spec:** `docs/superpowers/specs/2026-05-03-part-staff-type-safety-design.md`

**Branch:** Create `refactor/part-staff-type-safety`. All commits on this branch; squash/merge at end.

**Working assumption — ordering of changes:** Because every subsystem depends on `SheetMusicCore`'s `Score`/`Part`/`Staff` types, we cannot land Core in isolation and keep the build green. The strategy is to make ALL the breaking edits to Core + every consuming module under a SINGLE branch, then recover green compile and green tests in **Task 16 (compile sweep)** and **Task 17 (regression suite)**. Earlier per-module tasks each commit individually but **the project will not build cleanly between Task 1 and Task 15**. That is expected. Do not try to make `swift build` pass in Tasks 1–15.

---

## File Map

### Core type changes (single source of truth)

| File | Action | Responsibility |
|---|---|---|
| `Sources/SheetMusicCore/Score/Staff.swift` | **Create** | New unified `Staff` value type (replaces `StaffDeclaration` + `StaffContent`) |
| `Sources/SheetMusicCore/Score/StaffAddress.swift` | **Create** | Path-based ID `(partIndex, staffIndexInPart)` + Score subscript / `allStaves` |
| `Sources/SheetMusicCore/Score/Score.swift` | **Modify** | Drop `staves`, keep `parts` as the single truth |
| `Sources/SheetMusicCore/Score/Part.swift` | **Modify** | `staffDeclarations: [StaffDeclaration]` → `staves: [Staff]` |
| `Sources/SheetMusicCore/Score/StaffContent.swift` | **Delete** | Folded into `Staff` |
| `Sources/SheetMusicCore/Score/StaffDeclaration.swift` | **Delete** | Folded into `Staff` |

### ID types (path-based addressing)

| File | Action | Responsibility |
|---|---|---|
| `Sources/SheetMusicCore/Score/NoteID.swift` | **Modify** | `staffIndex: Int` → `staff: StaffAddress`, subscript walks `parts[…].staves[…]` |
| `Sources/SheetMusicCore/Score/RestID.swift` | **Modify** | Same |
| `Sources/SheetMusicCore/Editing/VoiceElementID.swift` | **Modify** | Same |

### Score+ extensions and Editing

| File | Action |
|---|---|
| `Sources/SheetMusicCore/Score/Score+ActiveKey.swift` | **Modify** — `activeKey(staff: StaffAddress, …)` |
| `Sources/SheetMusicCore/Score/Score+NextChord.swift` | **Modify** |
| `Sources/SheetMusicCore/Score/Score+NoteRange.swift` | **Modify** |
| `Sources/SheetMusicCore/Score/Score+TieTarget.swift` | **Modify** |
| `Sources/SheetMusicCore/Editing/DurationChangeAlgorithm.swift` | **Modify** — subscript `parts[…].staves[…]` |
| `Sources/SheetMusicCore/Editing/ReplaceVoiceElements.swift` | **Modify** — same |
| Other `Sources/SheetMusicCore/Editing/*.swift` | **Modify** — anywhere `score.staves[idx]` appears |

### MSCX decoder (rewrite for id-keyed pairing)

| File | Action |
|---|---|
| `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift` | **Modify** — id-keyed pairing |
| `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Part.swift` | **Modify** — return `(DecodedPart, [DeclaredStaff])` instead of `Part` directly |
| `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Staff.swift` | **Create** — replaces `+StaffDeclaration` + `+StaffContent`. Owns: declared-staff decoding, top-level-staff measures decoding, paired-Staff assembly |
| `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffDeclaration.swift` | **Delete** |
| `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffContent.swift` | **Delete** |

### MusicXML decoder

| File | Action |
|---|---|
| `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder.swift` | **Modify** — assemble parts with nested staves directly |
| `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Part.swift` | **Modify** — produce `[Staff]` |
| `Sources/SheetMusicMusicXML/Decoders/StaffMeasureBuilder.swift` | **Modify if needed** |

### MIDI render

| File | Action |
|---|---|
| `Sources/SheetMusicMIDI/Render/MidiRenderer.swift` | **Modify** — iterate `score.allStaves` |
| `Sources/SheetMusicMIDI/Render/MidiRenderer+Channels.swift` | **Modify** — delete `staffOwnership(score:)`, drop `StaffOwnership` struct |
| `Sources/SheetMusicMIDI/Render/MidiRenderer+Header.swift` | **Modify** — `staff: StaffContent` → `staff: Staff` |
| `Sources/SheetMusicMIDI/Render/MidiRenderer+Repeats.swift` | **Modify** — same |
| `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` | **Modify** — same |

### MIDI import

| File | Action |
|---|---|
| `Sources/SheetMusicMIDI/Import/MidiImporter+Assemble.swift` | **Modify** — emit nested `Part(…, staves: [Staff])`, drop separate `staves` array |

### Layout (the core bug fix)

| File | Action |
|---|---|
| `Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift` | **Modify** — iterate `score.allStaves`, label per-`address` |
| `Sources/SheetMusicLayout/Layout/LayoutEngine+Packing.swift` | **Modify** — `defaultClefRawTypes` takes `[(StaffAddress, Staff)]` and resolves via `address.partIndex` + `staffIndexInPart` |
| `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift` | **Modify** — `LayoutPartLabel` resolution by address |
| `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift` | **Modify** — type signatures `[StaffContent]` → `[Staff]` |
| `Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift` | **Modify** — same |
| `Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift` | **Modify** |
| `Sources/SheetMusicLayout/Layout/LayoutEngine+Lyrics.swift` | **Modify** |
| `Sources/SheetMusicLayout/Layout/LayoutMeasure.swift` | **Modify** — doc comment update |

### Audio / UI / PDF

| File | Action |
|---|---|
| `Sources/SheetMusicAudio/PlaybackEngine.swift` | **Modify** — iterate `score.allStaves`, `score[address]` |
| `Sources/SheetMusicAudio/PlaybackEngine+Mixer.swift` | **Modify** |
| `Sources/SheetMusicAudio/PlaybackTimeline.swift` | **Modify** |
| `Sources/SheetMusicAudio/MetronomeBeat.swift` | **Modify** |
| `Sources/SheetMusicUI/PlaybackCursorView.swift` | **Modify** |
| `Sources/SheetMusicUI/Selection/SelectionRenderState.swift` | **Modify** |
| `Sources/SheetMusicPDF/Import/PDFImporter+Assemble.swift` | **Modify** — emit nested `Part(staves:)` |
| `Sources/SheetMusicPDF/Import/PDFImporter+Layout.swift` | **Modify** — assemble via nested path |
| `Sources/RenderPreviews/main.swift` | **Modify** |
| `Sources/RenderPreviews/Samples.swift` | **Modify** — every `StaffContent(...)` literal becomes a nested `Staff` inside a `Part` |

### Tests

| File | Action |
|---|---|
| `Tests/SheetMusicTests/Resources/multiPartMixedStaves.mscx` | **Create** (MIT, hand-written) — Vln/Vln/Piano/Vc fixture |
| `Tests/SheetMusicTests/Resources/LICENSE` | **Modify** — note the new MIT-licensed fixture is excluded from the GPL section |
| `Tests/SheetMusicTests/StaffAddressTests.swift` | **Create** |
| `Tests/SheetMusicTests/ScoreAllStavesTests.swift` | **Create** |
| `Tests/SheetMusicTests/MultiPartStaffMappingTests.swift` | **Create** — MSCX id-pairing tests |
| `Tests/SheetMusicTests/LayoutPartLabelClefTests.swift` | **Create** — bug regression test |

---

## Phase Overview

1. **Tasks 1–4** — Core: new types (`Staff`, `StaffAddress`), modify `Score`/`Part`, delete old types
2. **Tasks 5–6** — Core IDs: NoteID/RestID/VoiceElementID, Score+ extensions, Editing
3. **Task 7** — MSCX decoder rebuild (id-keyed pairing + fallback)
4. **Task 8** — MusicXML decoder
5. **Task 9** — MIDI render
6. **Task 10** — MIDI import
7. **Task 11** — Layout (the bug-fix module)
8. **Task 12** — Audio
9. **Task 13** — UI
10. **Task 14** — PDF importer / RenderPreviews
11. **Task 15** — New test fixture + Core unit tests
12. **Task 16** — Project-wide compile sweep (first `swift build` pass after refactor)
13. **Task 17** — Full test suite + lint, fix any regressions
14. **Task 18** — Layout bug regression test (TDD: red then green via Task 11 work)
15. **Task 19** — Final verification + branch finish

---

## Task 1: Branch + Create `Staff` value type

**Files:**
- Create: `Sources/SheetMusicCore/Score/Staff.swift`

- [ ] **Step 1: Create branch**

```bash
git checkout -b refactor/part-staff-type-safety
```

- [ ] **Step 2: Write `Staff.swift`**

```swift
// Sources/SheetMusicCore/Score/Staff.swift
import Foundation

/// A single staff inside a `Part`. Unifies what was previously split
/// across `StaffDeclaration` (rendering hints, defaultClef) and
/// `StaffContent` (measures). Lives nested under its owning `Part`,
/// so order in `Part.staves` defines display order and identity.
///
/// C++: combines `mu::engraving::Staff` and the per-staff measure
/// chain that hangs off `Score`. The mscx file format keeps these
/// physically separated (`<Part><Staff id="N">` declares; top-level
/// `<Staff id="N">` carries measures). They are paired by id in the
/// decoder; the model collapses the split.
public struct Staff: Sendable, Equatable {
    /// MuseScore `<StaffType><name>` (e.g. "stdNormal").
    public var staffType: String
    /// MuseScore `<StaffType group="…">` (e.g. "pitched", "percussion").
    public var group: String
    /// MuseScore `<defaultClef>` (e.g. "G", "F", "PERC"). Layout
    /// engines synthesize the opening clef from this when the first
    /// content measure lacks an explicit `<Clef>`.
    public var defaultClefType: String?
    public var measures: [Measure]

    public init(
        staffType: String = "stdNormal",
        group: String = "pitched",
        defaultClefType: String? = nil,
        measures: [Measure] = []
    ) {
        self.staffType = staffType
        self.group = group
        self.defaultClefType = defaultClefType
        self.measures = measures
    }
}
```

- [ ] **Step 3: Confirm Core target picks the new file up**

Run: `swift build --target SheetMusicCore 2>&1 | head -20`

Expected: Likely passes if isolated, but downstream Score.swift still references the deleted types — defer green build to Task 16. At minimum, Staff.swift itself should not have compile errors. If it does, fix syntax now.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicCore/Score/Staff.swift
git commit -m "feat(core): add unified Staff type"
```

---

## Task 2: Create `StaffAddress` and Score-level helpers

**Files:**
- Create: `Sources/SheetMusicCore/Score/StaffAddress.swift`

- [ ] **Step 1: Write `StaffAddress.swift`**

```swift
// Sources/SheetMusicCore/Score/StaffAddress.swift
import Foundation

/// Path-based address of a `Staff` inside a `Score`:
/// `score.parts[partIndex].staves[staffIndexInPart]`.
///
/// `Comparable` orders by `(partIndex, staffIndexInPart)` lexicographically,
/// matching the engraver's top-to-bottom display order.
public struct StaffAddress: Hashable, Sendable, Comparable {
    public let partIndex: Int
    public let staffIndexInPart: Int

    public init(partIndex: Int, staffIndexInPart: Int) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.partIndex, lhs.staffIndexInPart)
            < (rhs.partIndex, rhs.staffIndexInPart)
    }
}

extension Score {
    /// Every staff in display order. Replaces the old flat
    /// `score.staves` iteration: enumerate to recover the legacy
    /// flat staffIndex if some downstream still needs it.
    public var allStaves: [(address: StaffAddress, staff: Staff)] {
        var result: [(address: StaffAddress, staff: Staff)] = []
        for (p, part) in parts.enumerated() {
            for (s, staff) in part.staves.enumerated() {
                result.append(
                    (StaffAddress(partIndex: p, staffIndexInPart: s),
                     staff)
                )
            }
        }
        return result
    }

    /// Number of staves in display order across all parts.
    public var totalStaffCount: Int {
        parts.reduce(0) { $0 + $1.staves.count }
    }

    /// Resolve an address to its `Staff`, or `nil` if out of range.
    public subscript(address: StaffAddress) -> Staff? {
        guard parts.indices.contains(address.partIndex) else { return nil }
        let part = parts[address.partIndex]
        guard part.staves.indices.contains(address.staffIndexInPart) else {
            return nil
        }
        return part.staves[address.staffIndexInPart]
    }

    /// Resolve to the owning `Part`.
    public func part(at address: StaffAddress) -> Part? {
        guard parts.indices.contains(address.partIndex) else { return nil }
        return parts[address.partIndex]
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/SheetMusicCore/Score/StaffAddress.swift
git commit -m "feat(core): add StaffAddress + Score.allStaves helpers"
```

---

## Task 3: Modify `Score` and `Part`, delete legacy types

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Score.swift`
- Modify: `Sources/SheetMusicCore/Score/Part.swift`
- Delete: `Sources/SheetMusicCore/Score/StaffContent.swift`
- Delete: `Sources/SheetMusicCore/Score/StaffDeclaration.swift`

- [ ] **Step 1: Rewrite `Score.swift`**

```swift
// Sources/SheetMusicCore/Score/Score.swift
import Foundation

/// Root of the parsed MuseScore document. C++: `mu::engraving::MasterScore`/`Score`.
public struct Score: Sendable, Equatable {
    public var division: Int
    public var parts: [Part]
    public var metaTags: [String: String]
    /// Title block (`<VBox>` in MuseScore) above the first system,
    /// when present.
    public var titleFrame: ScoreFrame?
    /// Subset of MuseScore's `<Style>` block.
    public var style: ScoreStyle

    public init(
        division: Int,
        parts: [Part] = [],
        metaTags: [String: String] = [:],
        titleFrame: ScoreFrame? = nil,
        style: ScoreStyle = .museScoreDefaults
    ) {
        self.division = division
        self.parts = parts
        self.metaTags = metaTags
        self.titleFrame = titleFrame
        self.style = style
    }
}
```

- [ ] **Step 2: Rewrite `Part.swift`**

```swift
// Sources/SheetMusicCore/Score/Part.swift
import Foundation

/// A score part (one instrument). Owns its staves directly.
/// C++: `mu::engraving::Part`.
public struct Part: Sendable, Equatable {
    public var id: String
    public var trackName: String?
    public var instrument: Instrument
    public var staves: [Staff]

    public init(
        id: String,
        trackName: String? = nil,
        instrument: Instrument,
        staves: [Staff] = []
    ) {
        self.id = id
        self.trackName = trackName
        self.instrument = instrument
        self.staves = staves
    }
}
```

- [ ] **Step 3: Delete legacy files**

```bash
git rm Sources/SheetMusicCore/Score/StaffContent.swift
git rm Sources/SheetMusicCore/Score/StaffDeclaration.swift
```

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicCore/Score/Score.swift Sources/SheetMusicCore/Score/Part.swift
git commit -m "refactor(core)!: nest Staff under Part, drop Score.staves

BREAKING: Score.staves removed; iterate score.allStaves or
score.parts[…].staves instead. StaffDeclaration and StaffContent
have been folded into the unified Staff type."
```

---

## Task 4: Refactor `NoteID` / `RestID` / `VoiceElementID` to use `StaffAddress`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/NoteID.swift`
- Modify: `Sources/SheetMusicCore/Score/RestID.swift`
- Modify: `Sources/SheetMusicCore/Editing/VoiceElementID.swift`

- [ ] **Step 1: Rewrite `NoteID.swift`**

```swift
// Sources/SheetMusicCore/Score/NoteID.swift
import Foundation

/// Path-based identity of a `Note` inside a `Score`. Walks
/// `score.parts[staff.partIndex].staves[staff.staffIndexInPart]
/// .measures[measure].voices[voice].elements[element]` (must be `.chord`)
/// and then into `Chord.notes[noteIndexInChord]`.
public struct NoteID: Hashable, Sendable {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elementIndex: Int
    public let noteIndexInChord: Int

    public init(
        staff: StaffAddress,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int,
        noteIndexInChord: Int
    ) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elementIndex = elementIndex
        self.noteIndexInChord = noteIndexInChord
    }
}

extension Score {
    public subscript(noteID: NoteID) -> Note? {
        guard let staff = self[noteID.staff] else { return nil }
        guard staff.measures.indices.contains(noteID.measureIndex) else { return nil }
        let voices = staff.measures[noteID.measureIndex].voices
        guard voices.indices.contains(noteID.voiceIndex) else { return nil }
        let elements = voices[noteID.voiceIndex].elements
        guard elements.indices.contains(noteID.elementIndex) else { return nil }
        guard case let .chord(chord) = elements[noteID.elementIndex] else { return nil }
        guard chord.notes.indices.contains(noteID.noteIndexInChord) else { return nil }
        return chord.notes[noteID.noteIndexInChord]
    }
}
```

- [ ] **Step 2: Rewrite `RestID.swift`**

```swift
// Sources/SheetMusicCore/Score/RestID.swift
import Foundation

/// Path-based identity of a rest inside a `Score`.
public struct RestID: Hashable, Sendable {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elementIndex: Int

    public init(
        staff: StaffAddress,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int
    ) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elementIndex = elementIndex
    }
}

extension Score {
    public subscript(restID: RestID) -> Chord? {
        guard let staff = self[restID.staff] else { return nil }
        guard staff.measures.indices.contains(restID.measureIndex) else { return nil }
        let voices = staff.measures[restID.measureIndex].voices
        guard voices.indices.contains(restID.voiceIndex) else { return nil }
        let elements = voices[restID.voiceIndex].elements
        guard elements.indices.contains(restID.elementIndex) else { return nil }
        guard case let .chord(chord) = elements[restID.elementIndex],
              chord.notes.isEmpty
        else { return nil }
        return chord
    }
}
```

- [ ] **Step 3: Rewrite `VoiceElementID.swift`**

```swift
// Sources/SheetMusicCore/Editing/VoiceElementID.swift
import Foundation

public struct VoiceElementID: Hashable, Sendable {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elementIndex: Int

    public init(
        staff: StaffAddress,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int
    ) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elementIndex = elementIndex
    }

    public init(_ id: RestID) {
        self.init(
            staff: id.staff,
            measureIndex: id.measureIndex,
            voiceIndex: id.voiceIndex,
            elementIndex: id.elementIndex
        )
    }

    public init(_ id: NoteID) {
        self.init(
            staff: id.staff,
            measureIndex: id.measureIndex,
            voiceIndex: id.voiceIndex,
            elementIndex: id.elementIndex
        )
    }
}

extension Score {
    public subscript(id: VoiceElementID) -> VoiceElement? {
        get {
            guard let staff = self[id.staff],
                  staff.measures.indices.contains(id.measureIndex)
            else { return nil }
            let voices = staff.measures[id.measureIndex].voices
            guard voices.indices.contains(id.voiceIndex) else { return nil }
            let elements = voices[id.voiceIndex].elements
            guard elements.indices.contains(id.elementIndex) else { return nil }
            return elements[id.elementIndex]
        }
        set {
            guard let newValue,
                  parts.indices.contains(id.staff.partIndex),
                  parts[id.staff.partIndex].staves.indices
                      .contains(id.staff.staffIndexInPart)
            else { return }
            let p = id.staff.partIndex
            let s = id.staff.staffIndexInPart
            guard parts[p].staves[s].measures.indices
                    .contains(id.measureIndex),
                  parts[p].staves[s].measures[id.measureIndex]
                    .voices.indices.contains(id.voiceIndex),
                  parts[p].staves[s].measures[id.measureIndex]
                    .voices[id.voiceIndex].elements.indices
                    .contains(id.elementIndex)
            else { return }
            parts[p].staves[s]
                .measures[id.measureIndex]
                .voices[id.voiceIndex]
                .elements[id.elementIndex] = newValue
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicCore/Score/NoteID.swift \
        Sources/SheetMusicCore/Score/RestID.swift \
        Sources/SheetMusicCore/Editing/VoiceElementID.swift
git commit -m "refactor(core)!: NoteID/RestID/VoiceElementID use StaffAddress"
```

---

## Task 5: Migrate Score+ extensions

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Score+ActiveKey.swift`
- Modify: `Sources/SheetMusicCore/Score/Score+NextChord.swift`
- Modify: `Sources/SheetMusicCore/Score/Score+NoteRange.swift`
- Modify: `Sources/SheetMusicCore/Score/Score+TieTarget.swift`

For each file: replace `staves[idx]` walk with `score[address]` resolution, replace `staffIndex: Int` parameters with `staff: StaffAddress`, update `NoteID(staffIndex:…)` constructions to `NoteID(staff:…)`.

- [ ] **Step 1: Rewrite `Score+ActiveKey.swift`**

The file currently has:
```swift
public func activeKey(staffIndex: Int, measureIndex: Int) -> Int {
    guard staffIndex >= 0, staffIndex < staves.count else { return 0 }
    let measures = staves[staffIndex].measures
    …
}
```

Replace with:
```swift
public func activeKey(staff: StaffAddress, measureIndex: Int) -> Int {
    guard let s = self[staff] else { return 0 }
    let measures = s.measures
    // …rest of body unchanged, using `measures` local
}
```

And `activeKey(at noteID:)` body:
```swift
return activeKey(
    staff: noteID.staff,
    measureIndex: noteID.measureIndex
)
```

- [ ] **Step 2: Rewrite `Score+NextChord.swift`**

Replace `let staffIndex = voiceElementID.staffIndex` and `staves[staffIndex]` → resolve via `self[voiceElementID.staff]`. Replace `NoteID(staffIndex: staffIndex, …)` → `NoteID(staff: voiceElementID.staff, …)`.

- [ ] **Step 3: Rewrite `Score+NoteRange.swift`**

The function iterates a staff range from `anchor.staffIndex` to `target.staffIndex`. With nested addressing the analogous range walk is over `allStaves`:

```swift
let anchorAddr = anchor.staff
let targetAddr = target.staff
let lo = min(anchorAddr, targetAddr)
let hi = max(anchorAddr, targetAddr)
for (addr, staff) in allStaves where (lo...hi).contains(addr) {
    let measures = staff.measures
    // …existing inner-loop logic, replacing `staffIndex: staffIdx` ID
    //   construction with `staff: addr`
}
```

`Comparable` on `StaffAddress` makes `(lo...hi)` work; the iteration is in display order.

For the existing helpers `intersectingNotes(forID id: NoteID)` and `noteAt(_ id: NoteID, …)`:
- Replace `staves.indices.contains(id.staffIndex)` with `self[id.staff] != nil`.
- Replace `staves[id.staffIndex].measures` with `self[id.staff]!.measures` (or, idiomatically, `guard let s = self[id.staff]…`).

- [ ] **Step 4: Rewrite `Score+TieTarget.swift`**

Same replacements: `staves.indices.contains(noteID.staffIndex)` → `self[noteID.staff] != nil`; `staves[noteID.staffIndex].measures` → resolved staff; `NoteID(staffIndex: …)` → `NoteID(staff: noteID.staff, …)`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/Score+*.swift
git commit -m "refactor(core)!: Score+ helpers use StaffAddress"
```

---

## Task 6: Migrate Editing layer

**Files:**
- Modify: `Sources/SheetMusicCore/Editing/DurationChangeAlgorithm.swift`
- Modify: `Sources/SheetMusicCore/Editing/ReplaceVoiceElements.swift`
- Modify: any other `Sources/SheetMusicCore/Editing/*.swift` that touches `score.staves`

- [ ] **Step 1: Inventory remaining Editing usages**

```bash
grep -rn 'staves\[\|staffIndex' Sources/SheetMusicCore/Editing/ | grep -v VoiceElementID
```

Expect hits in `DurationChangeAlgorithm.swift`, `ReplaceVoiceElements.swift`. List all matches before editing.

- [ ] **Step 2: Rewrite `ReplaceVoiceElements.swift`**

Currently:
```swift
guard score.staves.indices.contains(staffIndex) else { … }
guard score.staves[staffIndex].measures.indices.contains(…) else { … }
guard score.staves[staffIndex].measures[…].voices.indices.contains(…) else { … }
let priorVoice = score.staves[staffIndex].measures[…].voices[…]
score.staves[staffIndex].measures[…].voices[…].elements.replaceSubrange(…)
```

The function signature takes `staffIndex: Int` from a parameter. Change the parameter to `staff: StaffAddress` (if it's an internal helper invoked by edit commands; check call sites). Replace each `score.staves[staffIndex]` with `score.parts[staff.partIndex].staves[staff.staffIndexInPart]`. The mutation form must still go through `parts[…].staves[…]` for in-place writeback to work — `score[address]` is read-only.

Type signature change ripple: any caller of `ReplaceVoiceElements` that passes a flat `staffIndex` must now pass a `StaffAddress`. Trace via `grep -rn ReplaceVoiceElements Sources/`.

- [ ] **Step 3: Rewrite `DurationChangeAlgorithm.swift`**

```swift
// at line ~295
guard score.parts.indices.contains(id.staff.partIndex),
      score.parts[id.staff.partIndex].staves.indices
          .contains(id.staff.staffIndexInPart) else {
    …
}
let measures = score.parts[id.staff.partIndex]
    .staves[id.staff.staffIndexInPart].measures
```

Replace all subsequent `score.staves[id.staffIndex]` references the same way.

- [ ] **Step 4: Re-run inventory grep**

```bash
grep -rn 'score\.staves\|\.staffIndex' Sources/SheetMusicCore/
```

Expected: 0 matches. Anything left is a missed call site — fix before commit.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Editing/
git commit -m "refactor(core)!: editing pipeline uses StaffAddress"
```

---

## Task 7: Rebuild MSCX decoder around id-keyed pairing

**Files:**
- Create: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Staff.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Part.swift`
- Delete: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffContent.swift`
- Delete: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffDeclaration.swift`

The new pairing rule (per spec §3): inside-`<Part>` `<Staff id="N">` declarations claim measures from the top-level `<Staff id="N">` keyed by **id**. For id-less inside-Part `<Staff>` (single-Part / single-Staff case like `midi01.mscx`), fall back to consuming the next unconsumed top-level Staff in document order.

- [ ] **Step 1: Write `MSCXDecoder+Staff.swift`**

```swift
// Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Staff.swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Staff {
    /// Decodes the `<StaffType>` / `<defaultClef>` portion of an
    /// inside-`<Part><Staff>` element. Measures are added separately
    /// during pairing — see `assemble(parts:topLevelStaves:)`.
    static func declared(_ node: XMLTreeNode) -> (mscxID: String?, decl: Staff) {
        let staffTypeNode = node.first("StaffType")
        let staffType = staffTypeNode?.first("name")?.text ?? "stdNormal"
        let group = staffTypeNode?.attributes["group"] ?? "pitched"
        let defaultClef = node.first("defaultClef")?.text
        let mscxID = node.attributes["id"]
        return (mscxID, Staff(
            staffType: staffType,
            group: group,
            defaultClefType: defaultClef,
            measures: []
        ))
    }
}

/// Top-level `<Staff id="N">` measure block — id is required at this
/// level; raised in `decodeTopLevel` if missing.
struct MSCXTopLevelStaff {
    let mscxID: String
    let measures: [Measure]
}

extension MSCXTopLevelStaff {
    static func decode(_ node: XMLTreeNode) throws -> MSCXTopLevelStaff {
        guard let id = node.attributes["id"] else {
            throw SheetMusicError.malformedScore(
                reason: "top-level <Staff> missing id attribute"
            )
        }
        let measures = try node.all("Measure").map { try Measure.decode($0) }
        return MSCXTopLevelStaff(mscxID: id, measures: measures)
    }
}

/// Pairs declared (per-Part) staves with top-level (measures) staves.
/// Hybrid rule:
///   1. Declarations with an explicit id consume the matching top-level Staff.
///   2. Declarations without an id consume the next remaining top-level Staff
///      in document order.
///   3. Any top-level Staff left unconsumed is a malformed-score error.
struct MSCXStaffPairing {
    var partID: String
    var trackName: String?
    var instrument: Instrument
    var declared: [(mscxID: String?, staff: Staff)]
}

func assembleParts(
    decoded: [MSCXStaffPairing],
    topLevel: [MSCXTopLevelStaff]
) throws -> [Part] {
    var byID: [String: [Measure]] = [:]
    var orderedIDs: [String] = []
    for tl in topLevel {
        byID[tl.mscxID] = tl.measures
        orderedIDs.append(tl.mscxID)
    }
    var consumed: Set<String> = []
    var unconsumedQueue = orderedIDs

    var parts: [Part] = []
    for dp in decoded {
        var assembled: [Staff] = []
        for declared in dp.declared {
            let measures: [Measure]
            if let id = declared.mscxID {
                guard let m = byID[id] else {
                    throw SheetMusicError.malformedScore(reason:
                        "Part '\(dp.partID)' declares <Staff id=\"\(id)\"> but no top-level <Staff> with that id was found"
                    )
                }
                measures = m
                consumed.insert(id)
                unconsumedQueue.removeAll { $0 == id }
            } else {
                // Pop next unconsumed top-level Staff in document order.
                while let head = unconsumedQueue.first, consumed.contains(head) {
                    unconsumedQueue.removeFirst()
                }
                guard let head = unconsumedQueue.first,
                      let m = byID[head] else {
                    throw SheetMusicError.malformedScore(reason:
                        "Part '\(dp.partID)' has an id-less <Staff> declaration but no remaining top-level <Staff> to consume"
                    )
                }
                measures = m
                consumed.insert(head)
                unconsumedQueue.removeFirst()
            }
            var s = declared.staff
            s.measures = measures
            assembled.append(s)
        }
        parts.append(Part(
            id: dp.partID,
            trackName: dp.trackName,
            instrument: dp.instrument,
            staves: assembled
        ))
    }

    let leftover = orderedIDs.filter { !consumed.contains($0) }
    if !leftover.isEmpty {
        throw SheetMusicError.malformedScore(reason:
            "top-level <Staff id=\"\(leftover.joined(separator: ","))\"> not claimed by any Part"
        )
    }
    return parts
}
```

- [ ] **Step 2: Rewrite `MSCXDecoder+Part.swift` to return `MSCXStaffPairing`**

```swift
// Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Part.swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Part {
    /// Decode the per-`<Part>` declaration. Top-level `<Staff>` measures
    /// are paired in afterwards by `assembleParts`.
    static func decodePairing(_ node: XMLTreeNode) throws -> MSCXStaffPairing {
        let id = node.attributes["id"] ?? ""
        let declared = node.all("Staff").map { Staff.declared($0) }
        guard let instrNode = node.first("Instrument") else {
            throw SheetMusicError.malformedScore(reason: "Part missing <Instrument>")
        }
        let instrument = try Instrument.decode(instrNode)
        return MSCXStaffPairing(
            partID: id,
            trackName: node.first("trackName")?.text,
            instrument: instrument,
            declared: declared
        )
    }
}
```

- [ ] **Step 3: Rewrite `MSCXDecoder+Score.swift`**

```swift
// Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Score {
    static func decode(_ root: XMLTreeNode) throws -> Score {
        guard root.name == "museScore" else {
            throw SheetMusicError.malformedScore(reason:
                "root is <\(root.name)>, expected <museScore>")
        }
        guard let scoreNode = root.first("Score") else {
            throw SheetMusicError.malformedScore(reason: "missing <Score>")
        }
        guard let divisionText = scoreNode.first("Division")?.text,
              let division = Int(divisionText) else {
            throw SheetMusicError.malformedScore(reason: "missing <Division>")
        }

        let partPairings = try scoreNode.all("Part").map {
            try Part.decodePairing($0)
        }
        let topLevelStaves = try scoreNode.all("Staff").map {
            try MSCXTopLevelStaff.decode($0)
        }
        let parts = try assembleParts(
            decoded: partPairings, topLevel: topLevelStaves
        )

        var metaTags: [String: String] = [:]
        for tag in scoreNode.all("metaTag") {
            if let name = tag.attributes["name"] {
                metaTags[name] = tag.text
            }
        }

        // VBox under the first top-level Staff (= first Part's first Staff).
        var titleFrame: ScoreFrame?
        if let firstStaff = scoreNode.first("Staff") {
            for child in firstStaff.children {
                if child.name == "VBox" {
                    titleFrame = ScoreFrame.decode(vbox: child)
                    break
                }
                if child.name == "Measure" { break }
            }
        }

        let style: ScoreStyle
        if let styleNode = scoreNode.first("Style") {
            style = ScoreStyle.decode(style: styleNode)
        } else {
            style = .museScoreDefaults
        }
        return Score(
            division: division, parts: parts,
            metaTags: metaTags, titleFrame: titleFrame, style: style
        )
    }
}
```

- [ ] **Step 4: Delete `MSCXDecoder+StaffDeclaration.swift` and `MSCXDecoder+StaffContent.swift`**

```bash
git rm Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffDeclaration.swift
git rm Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffContent.swift
```

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/
git commit -m "refactor(mscx)!: id-keyed Part/Staff pairing with id-less fallback"
```

---

## Task 8: Migrate MusicXML decoder

**Files:**
- Modify: `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder.swift`
- Modify: `Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Part.swift`

MusicXML's structure is closer to the new model — each `<part>` has a known staff count. We build `[Staff]` directly inside each `Part` rather than maintaining the parallel `[StaffContent]` array.

- [ ] **Step 1: Modify `MusicXMLDecoder+Part.swift`**

Currently it builds `staffDeclarations: [StaffDeclaration]` repeating "stdNormal" / "pitched". Change to build `staves: [Staff]` with empty measures (filled later by the assembler).

```swift
// MusicXMLDecoder+Part.swift
extension Part {
    /// Build a Part from MusicXML <part-list> info; staff measures are
    /// filled in by the top-level decoder loop.
    static func make(
        id: String,
        trackName: String?,
        instrument: Instrument,
        staffCount: Int
    ) -> Part {
        let staves = Array(
            repeating: Staff(
                staffType: "stdNormal", group: "pitched",
                defaultClefType: nil, measures: []
            ),
            count: max(1, staffCount)
        )
        return Part(
            id: id, trackName: trackName,
            instrument: instrument, staves: staves
        )
    }
}
```

- [ ] **Step 2: Modify `MusicXMLDecoder.swift`**

Locate the function around line 95–135 that builds `parts` / `staves` and returns `(parts: [Part], staves: [StaffContent])`. Change the return type to `[Part]` (with measures populated inside each `Staff`):

```swift
internal func decodePartsAndStaves(...) throws -> [Part] {
    var parts: [Part] = []
    // for each <part>:
    var stavesForPart: [[Measure]] = Array(repeating: [], count: staffCount)
    // … existing measure-walk fills stavesForPart[staffIdx] …
    var partStaves: [Staff] = []
    for measures in stavesForPart {
        partStaves.append(Staff(
            staffType: "stdNormal", group: "pitched",
            defaultClefType: nil, measures: measures
        ))
    }
    parts.append(Part(
        id: ..., trackName: ..., instrument: ...,
        staves: partStaves
    ))
    return parts
}
```

Update the call site that previously did `Score(parts: parts, staves: staves)` to `Score(parts: parts)`.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicMusicXML/
git commit -m "refactor(musicxml)!: Part owns staves directly"
```

---

## Task 9: Migrate MIDI render

**Files:**
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer.swift`
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Channels.swift`
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Header.swift`
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Repeats.swift`
- Modify: `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`

The flat-staff iteration becomes nested. `staffOwnership(score:)` is no longer needed because the owner is right there: `(partIndex, staff)`.

- [ ] **Step 1: Drop `staffOwnership` and `StaffOwnership` struct**

In `MidiRenderer+Channels.swift`, remove `staffOwnership(score:)` and the `StaffOwnership` struct in `MidiRenderer.swift`.

- [ ] **Step 2: Rewrite `MidiRenderer.render(score:)` loop**

```swift
public static func render(score: Score) throws -> MidiFile {
    var tracks: [MidiTrack] = []
    let channelAssignments = assignChannels(score: score)
    var trackIndex = 0
    for (partIndex, part) in score.parts.enumerated() {
        let channels = channelAssignments[partIndex]
        let primaryChannel = channels.first?.channel ?? partIndex
        let port = part.instrument.channel.midiPort ?? 0
        for (s, staff) in part.staves.enumerated() {
            let track = renderTrack(
                staff: staff,
                part: part,
                primaryChannel: primaryChannel,
                channels: channels,
                port: port,
                isFirstTrack: trackIndex == 0,
                isTopOfPart: s == 0,
                division: score.division
            )
            tracks.append(track)
            trackIndex += 1
        }
    }
    return MidiFile(division: score.division, format: 1, tracks: tracks)
}
```

- [ ] **Step 3: Update parameter types in `+Header`, `+Repeats`, `+Voice`**

Replace every `staff: StaffContent` with `staff: Staff`. The body code that reads `staff.measures` is unchanged — `Staff` exposes the same `measures: [Measure]`.

In `MidiRenderer+Repeats.swift`:
```swift
static func chase(measureIndex: Int, staff: Staff, voiceIndex: Int) -> Voice {
    // body unchanged
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicMIDI/Render/
git commit -m "refactor(midi-render)!: iterate parts → staves directly, drop staffOwnership"
```

---

## Task 10: Migrate MIDI import

**Files:**
- Modify: `Sources/SheetMusicMIDI/Import/MidiImporter+Assemble.swift`

The current code accumulates a parallel `[StaffContent]` array AND attaches `[StaffDeclaration]` to each `Part`, then constructs `Score(parts: parts, staves: staves)`. New model: each `Part` owns the staves directly.

- [ ] **Step 1: Rewrite the assembly loop**

Replace patterns like:
```swift
var staves: [StaffContent] = []
…
var staff = StaffContent(id: staffID, measures: scoreMeasures)
…
into staff: inout StaffContent,
…
staves.append(staff)
…
let staffDecls: [StaffDeclaration] = […]
Part(…, staffDeclarations: staffDecls)
```

with:
```swift
// Build [Staff] directly from imported tracks
var staffMeasuresPerPartTrack: [[[Measure]]] = …  // partIdx → [trackIdx → measures]
…
let staves: [Staff] = trackMeasures.map { measures in
    Staff(
        staffType: "stdNormal", group: "pitched",
        defaultClefType: defaultClef, measures: measures
    )
}
Part(…, staves: staves)
```

The function that previously took `into staff: inout StaffContent` becomes `into staff: inout Staff` — same in-place mutation, new type.

- [ ] **Step 2: Update `Score` construction to `Score(parts: parts)`**

(no separate `staves:` argument).

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicMIDI/Import/
git commit -m "refactor(midi-import)!: assemble Part(staves:) directly"
```

---

## Task 11: Migrate Layout engine — **the bug-fix module**

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Packing.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Lyrics.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutMeasure.swift`

This is where the bug lived. The fix is the **type signature change itself**: passing `(StaffAddress, Staff)` pairs everywhere a flat staff was passed, and resolving labels / clefs through `address.partIndex`.

- [ ] **Step 1: Replace `[StaffContent]` with `[(StaffAddress, Staff)]` in helper signatures**

Any helper in `+Spacing.swift`, `+Packing.swift`, `+Wrapping.swift` whose signature is `staves: [StaffContent]` becomes:

```swift
staves: [(address: StaffAddress, staff: Staff)]
```

…with call sites passing `score.allStaves`. For functions that need positional access by flat index (e.g. `staves[staffIdx].measures`), prefer `enumerated()` over `score.allStaves` and read `entry.staff.measures`.

- [ ] **Step 2: Fix `defaultClefRawTypes` (the bug)**

`LayoutEngine+Packing.swift:314-327` — replace the buggy implementation:

```swift
static func defaultClefRawTypes(
    addresses: [(address: StaffAddress, staff: Staff)],
    parts: [Part]
) -> [String] {
    addresses.map { entry in
        // BUG (old): used `parts[idx].staffDeclarations.first` regardless of
        // whether `idx` referred to the same part. Now the address knows
        // which part owns this staff and which Staff inside it.
        let part = parts[entry.address.partIndex]
        let decl = part.staves[entry.address.staffIndexInPart]
        if let declared = decl.defaultClefType {
            return declared
        }
        if decl.group == "percussion" { return "PERC" }
        return "G"
    }
}
```

Update the only call site in `LayoutEngine+Contexts.swift`:

```swift
var clefs = defaultClefRawTypes(
    addresses: score.allStaves, parts: score.parts
)
```

- [ ] **Step 3: Fix `LayoutMeasureContext.partLabels` (the second arm of the bug)**

`LayoutEngine+Contexts.swift:66`:

```swift
// BUG (old): partLabels[idx] used parts[idx], which only works if
// staves align 1:1 with parts. With Piano, idx 3 → score.parts[3]
// instead of score.parts[2] (= the Piano).
let partLabels = score.allStaves.map { entry -> String in
    let part = score.parts[entry.address.partIndex]
    return part.trackName
        ?? part.instrument.longName
        ?? ""
}
```

- [ ] **Step 4: Fix `LayoutEngine+SystemBuild.swift:399` part label loop**

```swift
let labels: [LayoutPartLabel] = score.allStaves.enumerated().map { idx, entry in
    let part = score.parts[entry.address.partIndex]
    let text: String
    if isFirstSystem {
        text = part.trackName ?? part.instrument.longName ?? ""
    } else {
        text = part.instrument.shortName
            ?? part.trackName.map { String($0.prefix(3)) }
            ?? ""
    }
    let y = staffOrigins[idx].y + metrics.staffHeight / 2
    return LayoutPartLabel(text: text, origin: CGPoint(x: 4, y: y))
}
```

- [ ] **Step 5: Fix the per-staff drumset lookup in `+Packing.swift:362` and `+SystemBuild.swift:101-106`**

```swift
let part = score.parts[entry.address.partIndex]
let drumMap: [Int: Int]? =
    part.instrument.useDrumset ? part.instrument.drumLineMap : nil
```

(replaces the old `idx < score.parts.count ? score.parts[idx] : nil` guard).

- [ ] **Step 6: Sweep `+Lyrics`, `+Spanners`, `+Spacing` for `score.staves.enumerated()`**

Replace each with `score.allStaves.enumerated()`. The inner-loop body that reads `staff.measures` works unchanged (it's now `entry.staff.measures` or `staff.measures` after destructuring).

- [ ] **Step 7: Update doc comments**

`LayoutMeasure.swift:6` — update comment from "score.staves[*]" to "score.allStaves[*]".

`LayoutEngine+SystemBuild.swift:487` — same.

- [ ] **Step 8: Inventory check**

```bash
grep -rn 'score\.staves\|StaffContent\|StaffDeclaration\|staffDeclarations' Sources/SheetMusicLayout/
```

Expected: 0 matches.

- [ ] **Step 9: Commit**

```bash
git add Sources/SheetMusicLayout/
git commit -m "fix(layout)!: resolve part labels and default clefs by StaffAddress

Previously LayoutEngine assumed staff index = part index, which
broke for parts with multiple staves (e.g. Piano). Now each staff
carries (partIndex, staffIndexInPart), so part labels and default
clefs resolve through the owning part's actual staves."
```

---

## Task 12: Migrate Audio module

**Files:**
- Modify: `Sources/SheetMusicAudio/PlaybackEngine.swift`
- Modify: `Sources/SheetMusicAudio/PlaybackEngine+Mixer.swift`
- Modify: `Sources/SheetMusicAudio/PlaybackTimeline.swift`
- Modify: `Sources/SheetMusicAudio/MetronomeBeat.swift`

- [ ] **Step 1: `PlaybackEngine.swift`**

```swift
// line ~169
for entry in score.allStaves {
    // body uses entry.staff
}
// line ~260-263
guard let staff = score[noteID.staff] else { return … }
// (drops `noteID.staffIndex < score.staves.count` guard)
```

- [ ] **Step 2: `PlaybackEngine+Mixer.swift`**

```swift
channels.reserveCapacity(score.totalStaffCount + 1)
for _ in score.allStaves { … }
```

- [ ] **Step 3: `PlaybackTimeline.swift`**

```swift
// line ~134
let measureCount = score.parts.first?.staves.first?.measures.count ?? 0

// line ~148 (staff loop)
staffLoop: for entry in score.allStaves { let staff = entry.staff; … }

// line ~169 (voice0 lookup)
if let voice0 = score.parts.first?.staves.first?
    .measures[mi].voices.first { … }

// line ~181 (enumerated staves)
for (staffIdx, entry) in score.allStaves.enumerated() {
    let staff = entry.staff
    …
}
```

- [ ] **Step 4: `MetronomeBeat.swift`**

```swift
let measureCount = score.parts.first?.staves.first?.measures.count ?? 0
…
staffLoop: for entry in score.allStaves { let staff = entry.staff; … }
…
if let voice0 = score.parts.first?.staves.first?.measures[mi].voices.first { … }
```

- [ ] **Step 5: Inventory check**

```bash
grep -rn 'score\.staves\|StaffContent\|StaffDeclaration' Sources/SheetMusicAudio/
```

Expected: 0 matches.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicAudio/
git commit -m "refactor(audio)!: iterate score.allStaves"
```

---

## Task 13: Migrate UI module

**Files:**
- Modify: `Sources/SheetMusicUI/PlaybackCursorView.swift`
- Modify: `Sources/SheetMusicUI/Selection/SelectionRenderState.swift`

- [ ] **Step 1: `PlaybackCursorView.swift`**

```swift
// line 150
for (staffIdx, entry) in score.allStaves.enumerated() { let staff = entry.staff; … }
// line 263
guard let voice0 = score.parts.first?.staves.first?
    .measures.first?.voices.first else { … }
```

- [ ] **Step 2: `SelectionRenderState.swift`**

```swift
// line 98-100 — old: score.staves.indices.contains(tid.staffIndex)
guard let staff = score[tid.staff] else { … }
let measures = staff.measures
```

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicUI/
git commit -m "refactor(ui)!: resolve staves via StaffAddress"
```

---

## Task 14: Migrate PDF importer + RenderPreviews

**Files:**
- Modify: `Sources/SheetMusicPDF/Import/PDFImporter+Assemble.swift`
- Modify: `Sources/SheetMusicPDF/Import/PDFImporter+Layout.swift`
- Modify: `Sources/RenderPreviews/main.swift`
- Modify: `Sources/RenderPreviews/Samples.swift`

- [ ] **Step 1: `PDFImporter+Assemble.swift`**

Replace `StaffContent(id: idx + 1, measures: ms)` and `staffDeclarations: Array(repeating: StaffDeclaration(...), count: …)` with a single `Staff(staffType: "stdNormal", group: "pitched", defaultClefType: nil, measures: ms)` collected into the part's `staves`.

- [ ] **Step 2: `PDFImporter+Layout.swift`**

```swift
// line 143 — old: parts[p].staves[s].staff
// new: parts[p].staves[s] is itself the Staff
parts[p].staves[s].measures = makeMeasures(...)
```

(Likely already mutating; just adapt to the new path/type.)

- [ ] **Step 3: `RenderPreviews/main.swift`**

```swift
// line 182 — old: let trimmedStaves = score.staves.map { staff in
let trimmedScore: Score = {
    var s = score
    for p in s.parts.indices {
        for st in s.parts[p].staves.indices {
            // trim measures
            let trimmed = trim(s.parts[p].staves[st].measures)
            s.parts[p].staves[st].measures = trimmed
        }
    }
    return s
}()
```

Anywhere `StaffContent(...)` is used as a return type, drop it.

- [ ] **Step 4: `RenderPreviews/Samples.swift`**

This file has many `Score(... staves: [StaffContent(id: 1, measures: [m])])` literals. Each becomes:

```swift
Score(
    division: 480,
    parts: [
        Part(
            id: "1",
            instrument: .someInstrument,
            staves: [
                Staff(
                    staffType: "stdNormal",
                    group: "pitched",
                    measures: [m]
                )
            ]
        )
    ]
)
```

Where the existing literal includes a `Part` already (e.g. piano sample with two `StaffContent`s), merge the two staves under the single Part.

The piano sample at lines 122–124, 484–488, 626–627 has `[StaffContent(id: 1, measures: [rh]), StaffContent(id: 2, measures: [lh])]`. New form:

```swift
parts: [
    Part(
        id: "1",
        instrument: .piano,
        staves: [
            Staff(staffType: "stdNormal", group: "pitched",
                  defaultClefType: "G", measures: [rh]),
            Staff(staffType: "stdNormal", group: "pitched",
                  defaultClefType: "F", measures: [lh])
        ]
    )
]
```

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicPDF/ Sources/RenderPreviews/
git commit -m "refactor(pdf,previews)!: build nested Part(staves:)"
```

---

## Task 15: New test fixture + Core unit tests

**Files:**
- Create: `Tests/SheetMusicTests/Resources/multiPartMixedStaves.mscx`
- Create: `Tests/SheetMusicTests/StaffAddressTests.swift`
- Create: `Tests/SheetMusicTests/ScoreAllStavesTests.swift`
- Create: `Tests/SheetMusicTests/MultiPartStaffMappingTests.swift`
- Modify: `Tests/SheetMusicTests/Resources/LICENSE`

- [ ] **Step 1: Author `multiPartMixedStaves.mscx`** (MIT, hand-written)

Build a minimal valid mscx representing four Parts: Vln1 (1 staff), Vln2 (1 staff), Piano (2 staves), Vc (1 staff) — 5 top-level staves total. Use a simple single-measure 4/4 of whole-note rests. Each `<Part>` contains explicit `<Staff id="N">` declarations (so id pairing exercises the primary path); top-level `<Staff id="1">..."5">` carry one whole-rest measure each.

Skeleton (fill out instrument metadata to match valid mscx instrument decoder):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="4.60">
  <Score>
    <Division>480</Division>
    <Part id="1">
      <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType><defaultClef>G</defaultClef></Staff>
      <trackName>Violin 1</trackName>
      <Instrument id="violin">…</Instrument>
    </Part>
    <Part id="2">
      <Staff id="2"><StaffType group="pitched"><name>stdNormal</name></StaffType><defaultClef>G</defaultClef></Staff>
      <trackName>Violin 2</trackName>
      <Instrument id="violin">…</Instrument>
    </Part>
    <Part id="3">
      <Staff id="3"><StaffType group="pitched"><name>stdNormal</name></StaffType><defaultClef>G</defaultClef></Staff>
      <Staff id="4"><StaffType group="pitched"><name>stdNormal</name></StaffType><defaultClef>F</defaultClef></Staff>
      <trackName>Piano</trackName>
      <Instrument id="piano">…</Instrument>
    </Part>
    <Part id="4">
      <Staff id="5"><StaffType group="pitched"><name>stdNormal</name></StaffType><defaultClef>F</defaultClef></Staff>
      <trackName>Violoncello</trackName>
      <Instrument id="violoncello">…</Instrument>
    </Part>
    <Staff id="1"><Measure><voice><Rest><durationType>measure</durationType><duration>4/4</duration></Rest></voice></Measure></Staff>
    <Staff id="2"><Measure>…</Measure></Staff>
    <Staff id="3"><Measure>…</Measure></Staff>
    <Staff id="4"><Measure>…</Measure></Staff>
    <Staff id="5"><Measure>…</Measure></Staff>
  </Score>
</museScore>
```

Cross-check Instrument decoder requirements (see existing `midi01.mscx` for a minimal valid `<Instrument>`).

- [ ] **Step 2: Update `Tests/SheetMusicTests/Resources/LICENSE`**

Add a paragraph noting `multiPartMixedStaves.mscx` is **MIT-licensed, hand-authored, not derived from MuseScore's GPL fixtures**, contributed under the same MIT license as `Sources/`.

- [ ] **Step 3: Write `StaffAddressTests.swift`**

```swift
import Testing
@testable import SheetMusicCore

@Suite struct StaffAddressTests {
    @Test func ordering() {
        let a = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let b = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        let c = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        #expect(a < b)
        #expect(b < c)
        #expect(a < c)
        #expect(!(a < a))
    }

    @Test func equality() {
        #expect(StaffAddress(partIndex: 2, staffIndexInPart: 1)
                == StaffAddress(partIndex: 2, staffIndexInPart: 1))
        #expect(StaffAddress(partIndex: 2, staffIndexInPart: 1).hashValue
                == StaffAddress(partIndex: 2, staffIndexInPart: 1).hashValue)
    }
}
```

- [ ] **Step 4: Write `ScoreAllStavesTests.swift`**

```swift
import Testing
@testable import SheetMusicCore

@Suite struct ScoreAllStavesTests {
    private func mkScore() -> Score {
        let inst = Instrument.minimal(id: "x")  // helper if available; else build inline
        return Score(division: 480, parts: [
            Part(id: "1", instrument: inst, staves: [Staff(measures: [])]),
            Part(id: "2", instrument: inst, staves: [
                Staff(measures: []),
                Staff(measures: [])
            ]),
            Part(id: "3", instrument: inst, staves: [Staff(measures: [])])
        ])
    }

    @Test func displayOrder() {
        let s = mkScore()
        let addrs = s.allStaves.map(\.address)
        #expect(addrs == [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 1),
            StaffAddress(partIndex: 2, staffIndexInPart: 0)
        ])
        #expect(s.totalStaffCount == 4)
    }

    @Test func subscriptResolves() {
        let s = mkScore()
        #expect(s[StaffAddress(partIndex: 1, staffIndexInPart: 1)] != nil)
        #expect(s[StaffAddress(partIndex: 1, staffIndexInPart: 5)] == nil)
        #expect(s[StaffAddress(partIndex: 99, staffIndexInPart: 0)] == nil)
        #expect(s.part(at: StaffAddress(partIndex: 0, staffIndexInPart: 0))?.id == "1")
    }
}
```

(If `Instrument.minimal(id:)` doesn't exist, factor out a small helper inside the test file.)

- [ ] **Step 5: Write `MultiPartStaffMappingTests.swift`**

```swift
import Testing
import Foundation
@testable import SheetMusic
@testable import SheetMusicMSCX

@Suite struct MultiPartStaffMappingTests {
    private static func loadMixed() throws -> Score {
        let url = Bundle.module.url(
            forResource: "multiPartMixedStaves",
            withExtension: "mscx"
        )!
        return try MSCXParser.parse(url)
    }

    @Test func partsAndStavesShape() throws {
        let s = try Self.loadMixed()
        #expect(s.parts.count == 4)
        #expect(s.parts[2].staves.count == 2)
        #expect(s.parts[2].staves[0].defaultClefType == "G")
        #expect(s.parts[2].staves[1].defaultClefType == "F")
        #expect(s.allStaves.count == 5)
    }

    @Test func displayOrderMatchesSpec() throws {
        let s = try Self.loadMixed()
        let addrs = s.allStaves.map(\.address)
        #expect(addrs == [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
            StaffAddress(partIndex: 2, staffIndexInPart: 0),
            StaffAddress(partIndex: 2, staffIndexInPart: 1),
            StaffAddress(partIndex: 3, staffIndexInPart: 0),
        ])
    }

    @Test func midi01IdLessFallback() throws {
        // Pre-existing GPL fixture; verifies the id-less fallback path.
        let url = Bundle.module.url(
            forResource: "midi01", withExtension: "mscx"
        )!
        let s = try MSCXParser.parse(url)
        #expect(s.parts.count == 1)
        #expect(s.parts[0].staves.count == 1)
        #expect(s.parts[0].staves[0].measures.isEmpty == false)
    }

    @Test func unclaimedTopLevelStaffThrows() throws {
        // Build mscx in memory: declare 1 Staff in 1 Part, but 2 top-level staves.
        let xml = """
        <museScore version="4.60"><Score><Division>480</Division>
        <Part id="1">
          <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
          <Instrument id="voice"><longName>X</longName>…</Instrument>
        </Part>
        <Staff id="1"><Measure>…</Measure></Staff>
        <Staff id="9"><Measure>…</Measure></Staff>
        </Score></museScore>
        """
        // Simplest path: write to a tmp file and parse; verify it throws .malformedScore
        // about an unconsumed top-level <Staff id="9">.
        #expect(throws: SheetMusicError.self) {
            _ = try MSCXParser.parse(string: xml) // or whichever entry point exists
        }
    }
}
```

(Adjust to whatever in-memory parse helper exists; otherwise round-trip via `URL` to a tmp file.)

- [ ] **Step 6: Commit**

```bash
git add Tests/SheetMusicTests/Resources/multiPartMixedStaves.mscx \
        Tests/SheetMusicTests/Resources/LICENSE \
        Tests/SheetMusicTests/StaffAddressTests.swift \
        Tests/SheetMusicTests/ScoreAllStavesTests.swift \
        Tests/SheetMusicTests/MultiPartStaffMappingTests.swift
git commit -m "test: multi-part mixed-stave fixture + Core/MSCX unit tests"
```

---

## Task 16: Project-wide compile sweep

This is the **first build attempt** after the refactor. Many residual call sites will surface — fix them mechanically.

- [ ] **Step 1: Run swift build**

```bash
swift build 2>&1 | tee /tmp/build.log
```

Expected initially: errors. Common patterns:
- `score.staves` → replace
- `StaffContent` / `StaffDeclaration` → replace with `Staff` (and `staves:` instead of `staffDeclarations:`)
- `NoteID(staffIndex:…)` → `NoteID(staff:…)`
- `staffOwnership(…)` calls anywhere outside Render

- [ ] **Step 2: Iterate**

For each error class:
```bash
grep -rn '<failing pattern>' Sources/
```
…fix per the patterns introduced in Tasks 9–14. Re-run `swift build` until clean.

- [ ] **Step 3: Inventory remaining references (sanity check)**

```bash
grep -rn 'StaffContent\|StaffDeclaration\|staffDeclarations\|score\.staves\|staffOwnership' Sources/
```

Expected: 0 matches in `Sources/` (this is acceptance criterion §4 of the spec).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: complete project-wide migration to nested staves"
```

---

## Task 17: Test sweep + lint

- [ ] **Step 1: Run full test suite**

```bash
swift test 2>&1 | tee /tmp/test.log
```

Expected: All 48 existing tests + the 3 new test files (Tasks 15) green. Test files outside Tasks 1–15 will need similar mechanical updates (e.g. `MidiExportTests`, `MidiRendererTests` building synthetic scores with the old `staves:` argument).

- [ ] **Step 2: Inventory test failures**

```bash
grep -rn 'StaffContent\|StaffDeclaration\|staffDeclarations\|score\.staves\|staffIndex:' Tests/
```

Fix each:
- `Score(division: …, parts: […], staves: …)` → `Score(division: …, parts: […])` with parts rebuilt to nest staves
- `NoteID(staffIndex: 0, …)` → `NoteID(staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), …)`
- `RestID(staffIndex: …)`, `VoiceElementID(staffIndex: …)` likewise

Particular attention: `MidiExportTests`, `MidiImportRoundTripTests`, `LayoutCacheTests`, `ScoreActiveKeyTests`, `ScoreNextChordTests`, `MultiStaffAlignmentTests`, `PlaybackTimelineTests`, `ScoreLayerBuilderTests`, `SheetMusicFacadeTests`. Don't change the **assertions** — only the construction APIs.

- [ ] **Step 3: Re-run tests until 100% green**

```bash
swift test
```

Expected: all green.

- [ ] **Step 4: Lint**

```bash
swiftlint --quiet Sources Tests
```

Expected: 0 warnings/errors (acceptance criterion §3 of the spec).

- [ ] **Step 5: Commit**

```bash
git add Tests/
git commit -m "test: migrate test target to nested-staves API"
```

---

## Task 18: Layout bug regression test (TDD red→green confirmation)

This test was implicitly green-by-design after Task 11, but per the spec, prove it via a deliberate red→green using the new fixture.

**Files:**
- Create: `Tests/SheetMusicTests/LayoutPartLabelClefTests.swift`

- [ ] **Step 1: Add the test**

```swift
import Testing
import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicLayout

@Suite struct LayoutPartLabelClefTests {
    @Test func partLabelsAndDefaultClefsAlignWithMultiStavePart() throws {
        let url = Bundle.module.url(
            forResource: "multiPartMixedStaves",
            withExtension: "mscx"
        )!
        let score = try MSCXParser.parse(url)

        let contexts = LayoutEngine.measureContexts(for: score)
        guard let m0 = contexts.first else {
            Issue.record("no measure context"); return
        }
        // Display order is [Vln1, Vln2, Piano-RH, Piano-LH, Vc]
        #expect(m0.partLabels[0] == "Violin 1")
        #expect(m0.partLabels[1] == "Violin 2")
        #expect(m0.partLabels[2] == "Piano")
        #expect(m0.partLabels[3] == "Piano")  // same part as slot 2
        #expect(m0.partLabels[4] == "Violoncello")

        // Default clef chain expected: G, G, G, F, F.
        // The bug under repair was slot 4 picking up part4's `staffDeclarations.first`
        // (=G via incorrect fallback) instead of the F clef declared on Vc.
        #expect(m0.clefRawTypes == ["G", "G", "G", "F", "F"])
    }
}
```

- [ ] **Step 2: Run**

```bash
swift test --filter LayoutPartLabelClefTests
```

Expected: all green (Task 11 already corrected the resolution rule). Treat as a **regression sentinel** — if a future change re-introduces "staff index = part index" anywhere in `+Contexts.swift` / `+Packing.swift` / `+SystemBuild.swift`, this test will catch it.

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests/LayoutPartLabelClefTests.swift
git commit -m "test(layout): regression for part-label/clef alignment with multi-stave parts"
```

---

## Task 19: Final verification + branch finish

- [ ] **Step 1: Final inventory**

```bash
grep -rn 'StaffContent\|StaffDeclaration\|staffDeclarations\|score\.staves\|staffOwnership' Sources/ Tests/
```

Expected: 0 matches anywhere.

- [ ] **Step 2: Full green run**

```bash
swift build && swift test && swiftlint --quiet Sources Tests
```

Expected: build OK, 100% tests green (≥48 prior + new Core/MSCX/Layout tests), 0 lint warnings.

- [ ] **Step 3: Smoke-test the example app build (Mac path)**

Per project memory (visual verification uses `SheetMusicExampleMac`), regenerate and build the example to confirm the public API change doesn't break the published façade:

```bash
cd Example && xcodegen generate
xcodebuild -project Example/SheetMusicExample.xcodeproj \
  -scheme SheetMusicExample -destination 'platform=macOS' \
  build -skipPackagePluginValidation 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED. (No simulator runs needed unless the user requests visual verification.)

- [ ] **Step 4: Hand off**

Branch is ready. Call out for the user: PR title / body, decision on merge strategy. Per spec acceptance criteria, summarize:
1. ✅ All 48 existing tests + new tests green
2. ✅ `multiPartMixedStaves.mscx` regression test green
3. ✅ swiftlint clean
4. ✅ `Score.staves`/`StaffContent`/`StaffDeclaration`/`staffOwnership` removed
5. ✅ README library table untouched

---

## Self-Review

**Spec coverage check:**

- §1 type layout (Score/Part/Staff/StaffAddress) — Tasks 1–3 ✓
- §2 NoteID/RestID/VoiceElementID with StaffAddress — Tasks 4 ✓
- §2 score.allStaves, subscript, part(at:) — Task 2 ✓
- §3 MSCX id-keyed pairing + id-less fallback + unconsumed-staff fail — Task 7 ✓
- §3 `MSCXDecoder+StaffContent` merged into `+Staff` — Task 7 ✓
- §3 titleFrame stays on first top-level Staff — Task 7 step 3 ✓
- §3 MusicXML decoder Part-internal Staff construction — Task 8 ✓
- §3 `MidiImporter+Assemble` Part-internal Staff construction — Task 10 ✓
- §4 SheetMusicCore — Tasks 1–6 ✓
- §4 SheetMusicMSCX — Task 7 ✓
- §4 SheetMusicMusicXML — Task 8 ✓
- §4 SheetMusicMIDI render (drop staffOwnership) — Task 9 ✓
- §4 SheetMusicLayout (the bug fix) — Task 11 ✓
- §4 SheetMusicAudio — Task 12 ✓
- §4 SheetMusicUI — Task 13 ✓
- §4 SheetMusicPDF (importer paused but assemble path adapted) — Task 14 ✓
- §4 RenderPreviews / Examples — Task 14 ✓
- §4 Tests `@testable` migration — Task 17 ✓
- §5 regression suite green (48 tests) — Task 17 ✓
- §5 `MidiExportTests.midiMeasureRepeats` (Piano fixture) green — Task 17 ✓
- §5 swiftlint clean — Task 17 ✓
- §5 StaffAddressTests, Score+AllStavesTests — Task 15 ✓
- §5 multi-part fixture + parts.count==4, parts[2].staves.count==2, allStaves.count==5 — Task 15 ✓
- §5 unclaimed top-level Staff throws — Task 15 ✓
- §5 Layout bug regression test — Task 18 ✓
- §5 Fixture is MIT, test-only, not derived from GPL — Task 15 step 1–2 ✓
- §6 acceptance criteria — Task 19 ✓

**Placeholder scan:** No "TBD" / "implement later" / vague handwaves. Every code-bearing step shows the actual code or a concrete grep + transformation rule.

**Type consistency:**
- `StaffAddress(partIndex:staffIndexInPart:)` used uniformly.
- `Staff(staffType:group:defaultClefType:measures:)` initializer used uniformly.
- `Score(division:parts:metaTags:titleFrame:style:)` (no `staves:` arg) used uniformly.
- `NoteID(staff:measureIndex:voiceIndex:elementIndex:noteIndexInChord:)` used uniformly.
- `score[address]` for read, `score.parts[p].staves[s].measures[…]` for in-place writes — distinction noted in Task 6 step 2.
- `score.allStaves` returns `[(address: StaffAddress, staff: Staff)]` consistently.
