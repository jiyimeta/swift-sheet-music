# Clef Selection and Replacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users of the macOS example app to tap a clef in the rendered score and replace it with one of four choices (G, G8vb, F, F8vb), with the underlying selection/edit primitives exposed at the library level for any host.

**Architecture:** Selection identity flows end-to-end via a new `ClefAnchor` value (`.explicit(VoiceElementID)` or `.staffDefault(StaffAddress)`). `LayoutElement.clef` carries this anchor (or `nil` for continuation-system header restatements that are not selectable). A new `SetStaffDefaultClef` `EditCommand` covers the staff-default path; the existing `ReplaceVoiceElement` covers explicit clefs. The macOS example wires a 2×2 SwiftUI popover anchored to the clef glyph's bounding rect.

**Tech Stack:** Swift Package Manager, Swift Testing, SwiftUI (macOS popover), CoreGraphics + QuartzCore (CALayer-based rendering), Bravura SMuFL.

---

## File Structure

**Create:**
- `Sources/SheetMusicCore/Score/ClefAnchor.swift`
- `Sources/SheetMusicCore/Editing/SetStaffDefaultClef.swift`
- `Example/SheetMusicExample/macOS/ClefPopover.swift`
- `Tests/SheetMusicTests/EditingTests/SetStaffDefaultClefTests.swift`
- `Tests/SheetMusicTests/ClefAnchorTests.swift`
- `Tests/SheetMusicTests/LayoutElementClefAnchorTests.swift`
- `Tests/SheetMusicTests/ScoreHitTesterClefTests.swift`

**Modify:**
- `Sources/SheetMusicCore/Score/ScoreItemID.swift` — add `.clef(ClefAnchor)` case + accessors
- `Sources/SheetMusicLayout/Layout/LayoutElement.swift` — extend `.clef` case payload
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` — emit anchor for explicit + staff-default
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift` — emit `anchor: nil` for continuation header
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift` — preserve anchor through shift
- `Sources/SheetMusicUI/Selection/ScoreHitTarget.swift` — add `.clef(ClefAnchor)` case
- `Sources/SheetMusicUI/Selection/ScoreHitTester.swift` — add `hitClef`, extend `itemID(at:)`, add `clefHitRect(for:)` accessor
- `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift` — pass anchor to `drawClef`
- `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Notation.swift` — `drawClef` accepts `tint: CGColor?`
- `Sources/SheetMusicUI/PlaybackCursorView.swift` — handle new `.clef` case (no-op like `.tuplet`)
- `Example/SheetMusicExample/macOS/ContentViewMac.swift` — popover state, tap branch, edit dispatch

---

## Task 1: `ClefAnchor` value type

**Files:**
- Create: `Sources/SheetMusicCore/Score/ClefAnchor.swift`
- Test: `Tests/SheetMusicTests/ClefAnchorTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/SheetMusicTests/ClefAnchorTests.swift`:

```swift
import Testing
@testable import SheetMusicCore

@Suite("ClefAnchor")
struct ClefAnchorTests {
    @Test("explicit and staffDefault are distinct under Hashable")
    func explicitAndStaffDefaultDiffer() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let veID = VoiceElementID(
            staff: staff, measureIndex: 0,
            voiceIndex: 0, elementIndex: 0
        )
        let a: ClefAnchor = .explicit(veID)
        let b: ClefAnchor = .staffDefault(staff)
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test("equal staffDefault anchors hash equal")
    func staffDefaultEquality() {
        let staff = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        #expect(ClefAnchor.staffDefault(staff)
            == ClefAnchor.staffDefault(staff))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ClefAnchorTests`
Expected: FAIL — `ClefAnchor` is not defined.

- [ ] **Step 3: Implement `ClefAnchor`**

Create `Sources/SheetMusicCore/Score/ClefAnchor.swift`:

```swift
import Foundation

/// Identifies a specific clef instance in a `Score` for selection
/// and editing.
///
/// - `.explicit` — a `VoiceElement.clef(Clef)` at a known voice-element
///   location.
/// - `.staffDefault` — the synthesized opening clef rendered when the
///   first measure has no explicit `<Clef>`; sourced from
///   `Staff.defaultClefType`.
public enum ClefAnchor: Hashable, Sendable {
    case explicit(VoiceElementID)
    case staffDefault(StaffAddress)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ClefAnchorTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/ClefAnchor.swift \
        Tests/SheetMusicTests/ClefAnchorTests.swift
git commit -m "core: add ClefAnchor for clef-selection identity"
```

---

## Task 2: `ScoreItemID.clef(ClefAnchor)` case + accessor extension

**Files:**
- Modify: `Sources/SheetMusicCore/Score/ScoreItemID.swift`
- Modify: `Sources/SheetMusicUI/PlaybackCursorView.swift:243-267`
- Modify: `Sources/SheetMusicUI/Selection/ScoreHitTester.swift:86-93`
- Test: append to `Tests/SheetMusicTests/ClefAnchorTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/ClefAnchorTests.swift`:

```swift
@Suite("ScoreItemID.clef")
struct ScoreItemIDClefTests {
    @Test("staffDefault accessors return staff and zero indices")
    func staffDefaultAccessors() {
        let staff = StaffAddress(partIndex: 2, staffIndexInPart: 1)
        let id: ScoreItemID = .clef(.staffDefault(staff))
        #expect(id.staff == staff)
        #expect(id.measureIndex == 0)
        #expect(id.voiceIndex == 0)
        #expect(id.elementIndex == 0)
    }

    @Test("explicit accessors mirror the underlying VoiceElementID")
    func explicitAccessors() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let veID = VoiceElementID(
            staff: staff, measureIndex: 3,
            voiceIndex: 1, elementIndex: 2
        )
        let id: ScoreItemID = .clef(.explicit(veID))
        #expect(id.staff == staff)
        #expect(id.measureIndex == 3)
        #expect(id.voiceIndex == 1)
        #expect(id.elementIndex == 2)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ScoreItemIDClefTests`
Expected: FAIL — `ScoreItemID` has no `.clef` case.

- [ ] **Step 3: Add the `.clef` case to `ScoreItemID`**

Edit `Sources/SheetMusicCore/Score/ScoreItemID.swift` (replace the entire file):

```swift
import Foundation

/// A selectable score item — a specific notehead (`NoteID`), a
/// rest (`RestID`), a tuplet bracket (`TupletID`), or a clef
/// (`ClefAnchor`).
///
/// Produced by hit-testing and consumed by selection APIs.
public enum ScoreItemID: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)
    case tuplet(TupletID)
    case clef(ClefAnchor)

    public var staff: StaffAddress {
        switch self {
        case let .note(id): return id.staff
        case let .rest(id): return id.staff
        case let .tuplet(id): return id.staff
        case let .clef(.explicit(id)): return id.staff
        case let .clef(.staffDefault(staff)): return staff
        }
    }

    public var measureIndex: Int {
        switch self {
        case let .note(id): return id.measureIndex
        case let .rest(id): return id.measureIndex
        case let .tuplet(id): return id.measureIndex
        case let .clef(.explicit(id)): return id.measureIndex
        case .clef(.staffDefault): return 0
        }
    }

    public var voiceIndex: Int {
        switch self {
        case let .note(id): return id.voiceIndex
        case let .rest(id): return id.voiceIndex
        case let .tuplet(id): return id.voiceIndex
        case let .clef(.explicit(id)): return id.voiceIndex
        case .clef(.staffDefault): return 0
        }
    }

    /// Element index of this item — for tuplets this is the
    /// `startElementIndex` (the first member). For staff-default
    /// clefs this is `0` (a positional approximation; the
    /// authoritative target is the `ClefAnchor` itself).
    public var elementIndex: Int {
        switch self {
        case let .note(id): return id.elementIndex
        case let .rest(id): return id.elementIndex
        case let .tuplet(id): return id.startElementIndex
        case let .clef(.explicit(id)): return id.elementIndex
        case .clef(.staffDefault): return 0
        }
    }
}
```

- [ ] **Step 4: Update `PlaybackCursorView.itemX(_:in:)` for the new case**

Edit `Sources/SheetMusicUI/PlaybackCursorView.swift` around line 262, replacing the existing `case .tuplet:` arm:

```swift
        case .tuplet, .clef:
            // Playback cursor never positions on a tuplet bracket
            // or a clef — these are display-only selection targets,
            // not tick anchors.
            return nil
```

- [ ] **Step 5: Update `ScoreHitTester.itemID(at:)` to leave clefs unhandled for now**

Edit `Sources/SheetMusicUI/Selection/ScoreHitTester.swift` lines 86-93. The body keeps the existing three cases but the switch is over `ScoreHitTarget` (not `ScoreItemID`), so this file does not strictly need a change yet. **No edit required at this step**; the new clef branch is added in Task 6.

- [ ] **Step 6: Build the package to surface any other exhaustive-switch breaks**

Run: `swift build`
Expected: **success**, possibly with a warning that `Score+NoteRange.tickPosition` accepts the new case via index accessors (no exhaustive switch on the enum). If a compile error surfaces in any other file, add a minimal `case .clef: return nil` (or analogous) for that site so the build is green; report any unexpected callsite in the commit body.

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: 4 new tests pass; all existing tests stay green.

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicCore/Score/ScoreItemID.swift \
        Sources/SheetMusicUI/PlaybackCursorView.swift \
        Tests/SheetMusicTests/ClefAnchorTests.swift
git commit -m "core: add ScoreItemID.clef(ClefAnchor) case"
```

---

## Task 3: `SetStaffDefaultClef` EditCommand

**Files:**
- Create: `Sources/SheetMusicCore/Editing/SetStaffDefaultClef.swift`
- Test: `Tests/SheetMusicTests/EditingTests/SetStaffDefaultClefTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/EditingTests/SetStaffDefaultClefTests.swift`:

```swift
import Testing
@testable import SheetMusicCore

@Suite("SetStaffDefaultClef")
struct SetStaffDefaultClefTests {
    private func twoStaffScore(
        firstDefault: String? = "G",
        secondDefault: String? = "F"
    ) -> Score {
        let staff0 = Staff(
            staffType: "stdNormal", group: "",
            defaultClefType: firstDefault, brackets: [],
            measures: [Measure(voices: [Voice(elements: [])])]
        )
        let staff1 = Staff(
            staffType: "stdNormal", group: "",
            defaultClefType: secondDefault, brackets: [],
            measures: [Measure(voices: [Voice(elements: [])])]
        )
        let part = Part(
            id: "P1", trackName: nil,
            instrument: Instrument.empty,
            staves: [staff0, staff1]
        )
        return Score(parts: [part])
    }

    @Test("apply writes new value and inverse restores the previous one")
    func applyAndInverseRoundTrip() throws {
        var score = twoStaffScore()
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let cmd = SetStaffDefaultClef(staff: staff, newRawType: "F")
        let inverse = try cmd.apply(to: &score)
        #expect(score[staff]?.defaultClefType == "F")

        var afterUndo = score
        _ = try inverse.apply(to: &afterUndo)
        #expect(afterUndo[staff]?.defaultClefType == "G")
    }

    @Test("nil clears the default and inverse re-sets it")
    func nilClearsAndRestores() throws {
        var score = twoStaffScore(firstDefault: "G")
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let cmd = SetStaffDefaultClef(staff: staff, newRawType: nil)
        let inverse = try cmd.apply(to: &score)
        #expect(score[staff]?.defaultClefType == nil)

        _ = try inverse.apply(to: &score)
        #expect(score[staff]?.defaultClefType == "G")
    }

    @Test("invalid staff throws .invalidEdit")
    func invalidStaffThrows() {
        var score = twoStaffScore()
        let bogus = StaffAddress(partIndex: 9, staffIndexInPart: 0)
        let cmd = SetStaffDefaultClef(staff: bogus, newRawType: "G")
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
```

> If `Instrument.empty` is not available, replace with whatever zero-arg
> `Instrument` initializer the existing fixtures use; check
> `Tests/SheetMusicTests/EditingTests/EditingFixtures.swift` for the
> idiomatic way to build a test `Score` and adopt that pattern.
> The shape of the test (apply → inverse → re-apply) must not change.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SetStaffDefaultClefTests`
Expected: FAIL — `SetStaffDefaultClef` is not defined.

- [ ] **Step 3: Implement `SetStaffDefaultClef`**

Create `Sources/SheetMusicCore/Editing/SetStaffDefaultClef.swift`:

```swift
import Foundation

/// Sets `Staff.defaultClefType` for the staff at `staff`.
///
/// `nil` clears the default. The inverse command restores the
/// previous value (including `nil`).
public struct SetStaffDefaultClef: EditCommand {
    public let staff: StaffAddress
    public let newRawType: String?

    public init(staff: StaffAddress, newRawType: String?) {
        self.staff = staff
        self.newRawType = newRawType
    }

    /// Synthetic anchor at the start of the staff. The staff-default
    /// clef has no element location of its own; this satisfies the
    /// `EditCommand` contract for diagnostics / logging.
    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: staff, measureIndex: 0,
            voiceIndex: 0, elementIndex: 0
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices
                  .contains(staff.staffIndexInPart)
        else {
            throw SheetMusicError.invalidEdit(
                reason: "SetStaffDefaultClef: no staff at \(staff)")
        }
        let p = staff.partIndex
        let s = staff.staffIndexInPart
        let previous = score.parts[p].staves[s].defaultClefType
        score.parts[p].staves[s].defaultClefType = newRawType
        return SetStaffDefaultClef(staff: staff, newRawType: previous)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SetStaffDefaultClefTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Editing/SetStaffDefaultClef.swift \
        Tests/SheetMusicTests/EditingTests/SetStaffDefaultClefTests.swift
git commit -m "core: add SetStaffDefaultClef edit command"
```

---

## Task 4: `LayoutElement.clef` carries an anchor

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift:15`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift:357-405`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift:243-251`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift:16-17`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift:28-32`
- Test: `Tests/SheetMusicTests/LayoutElementClefAnchorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/LayoutElementClefAnchorTests.swift`:

```swift
import Testing
@testable import SheetMusicCore
@testable import SheetMusicLayout

@available(macOS 15.0, iOS 16.0, *)
@Suite("LayoutElement.clef anchor")
struct LayoutElementClefAnchorTests {
    @Test("staff-default clef anchor at first measure of first system")
    func staffDefaultAnchor() throws {
        let url = try #require(Bundle.module.url(
            forResource: "midi05",
            withExtension: "mscx"))
        let score = try MSCXParser.parse(contentsOf: url)
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 18, systemGap: 16,
                                      wrapToViewWidth: false),
            availableWidth: 2000)
        let firstMeasure = try #require(
            doc.systems.first?.measures.first)
        let anchors = firstMeasure.elements.compactMap { el -> ClefAnchor? in
            guard case let .clef(_, _, anchor) = el else { return nil }
            return anchor
        }
        #expect(anchors.contains { anchor in
            if case .staffDefault = anchor { return true }
            return false
        })
    }

    @Test("continuation-system header clef has nil anchor")
    func continuationHeaderHasNilAnchor() throws {
        let url = try #require(Bundle.module.url(
            forResource: "midi05",
            withExtension: "mscx"))
        let score = try MSCXParser.parse(contentsOf: url)
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 18, systemGap: 16,
                                      wrapToViewWidth: true),
            availableWidth: 200)  // tight width forces multiple systems
        guard doc.systems.count >= 2 else {
            // Fixture was too short to wrap — rely on the
            // sticky-header path test below as a fallback.
            return
        }
        let secondSystemFirstMeasure = try #require(
            doc.systems.dropFirst().first?.measures.first)
        for el in secondSystemFirstMeasure.elements {
            if case let .clef(_, _, anchor) = el {
                #expect(anchor == nil,
                        "continuation-system header clefs must not be selectable")
            }
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LayoutElementClefAnchorTests`
Expected: FAIL — `LayoutElement.clef` does not have a third payload yet.

- [ ] **Step 3: Extend `LayoutElement.clef`**

Edit `Sources/SheetMusicLayout/Layout/LayoutElement.swift:15`:

```swift
case clef(rawType: String, origin: CGPoint, anchor: ClefAnchor?)
```

- [ ] **Step 4: Update emitter for synthesized leading clef in `+Placement.swift`**

Edit `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift:359-366` (the `remainingSynthClef` branch):

```swift
            // Emit the synthesized leading clef exactly once, at the top
            // of the first voice to process it.
            if remainingSynthClef, let rawType = initialClefRawType {
                out.append(.clef(
                    rawType: rawType,
                    origin: CGPoint(
                        x: headerSchedule.clefX, y: staffMidY
                    ),
                    anchor: .staffDefault(staffAddress)
                ))
                remainingSynthClef = false
            }
```

- [ ] **Step 5: Update emitter for explicit voice-element clef in `+Placement.swift`**

Edit `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift:398-405` (the `case let .clef(clef):` branch). The voice-element loop is `for (voiceElemIdx, el) in voice.elements.enumerated()`, with `staffAddress`, `measureIndex`, `voiceIdx` already in scope:

```swift
                case let .clef(clef):
                    currentClef = NotatedClef(rawType: clef.concertClefType)
                    let clefX = inHeader ? headerSchedule.clefX
                        : timedX(atTick: tickCursor)
                    let veID = VoiceElementID(
                        staff: staffAddress,
                        measureIndex: measureIndex,
                        voiceIndex: voiceIdx,
                        elementIndex: voiceElemIdx
                    )
                    out.append(.clef(
                        rawType: clef.concertClefType,
                        origin: CGPoint(x: clefX, y: staffMidY),
                        anchor: .explicit(veID)
                    ))
```

- [ ] **Step 6: Update emitter for continuation-header clef in `+Contexts.swift`**

Edit `Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift:247-250`:

```swift
                elements.append(.clef(
                    rawType: context.clefRawTypes[staffIdx],
                    origin: CGPoint(x: clefX, y: staffMidY),
                    anchor: nil
                ))
```

- [ ] **Step 7: Update `translate(...)` to preserve the new field**

Edit `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift:16-17`:

```swift
        case let .clef(t, p, anchor):
            return .clef(rawType: t, origin: shift(p), anchor: anchor)
```

- [ ] **Step 8: Update the renderer dispatch site**

Edit `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift:28-32`:

```swift
        case let .clef(raw, p, _):
            drawClef(
                rawType: raw, origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
```

(The `_` ignores `anchor` for now; Task 6 will use it for tinting.)

- [ ] **Step 9: Search for any other pattern matches that fail to compile**

Run: `swift build`
Expected: build succeeds. If any file fails to compile because of a clef pattern that takes 2 payloads, fix the destructuring there to take 3 (`anchor: _` if the site doesn't need it).

- [ ] **Step 10: Run the new and existing tests**

Run: `swift test`
Expected: 2 new tests in `LayoutElementClefAnchorTests` pass; all existing tests stay green.

- [ ] **Step 11: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutElement.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift \
        Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift \
        Tests/SheetMusicTests/LayoutElementClefAnchorTests.swift
git commit -m "layout: thread ClefAnchor through LayoutElement.clef"
```

---

## Task 5: `ScoreHitTarget.clef` + hit-test

**Files:**
- Modify: `Sources/SheetMusicUI/Selection/ScoreHitTarget.swift`
- Modify: `Sources/SheetMusicUI/Selection/ScoreHitTester.swift` (add `hitClef`, dispatch from `hitTestMeasure`, extend `itemID(at:)`, add `clefHitRect(for:)`)
- Test: `Tests/SheetMusicTests/ScoreHitTesterClefTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/ScoreHitTesterClefTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicUI

@available(macOS 15.0, iOS 16.0, *)
@Suite("ScoreHitTester — clef")
struct ScoreHitTesterClefTests {
    private func loadDoc(width: CGFloat = 2000) throws
        -> (LayoutDocument, Score)
    {
        let url = try #require(Bundle.module.url(
            forResource: "midi05",
            withExtension: "mscx"))
        let score = try MSCXParser.parse(contentsOf: url)
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(
                staffSize: 18, systemGap: 16,
                wrapToViewWidth: false),
            availableWidth: width)
        return (doc, score)
    }

    @Test("hit on leading G clef returns .clef(.staffDefault(...))")
    func hitsLeadingClef() throws {
        let (doc, _) = try loadDoc()
        let tester = ScoreHitTester(document: doc)
        let system = try #require(doc.systems.first)
        let measure = try #require(system.measures.first)
        let clefEl = try #require(measure.elements.first {
            if case .clef = $0 { return true }
            return false
        })
        guard case let .clef(_, origin, _) = clefEl else {
            Issue.record("expected first element to be a clef")
            return
        }
        let point = CGPoint(
            x: system.origin.x + measure.origin.x + origin.x,
            y: system.origin.y + measure.origin.y + origin.y
        )
        let target = tester.hitTest(at: point)
        guard case let .clef(anchor) = target else {
            Issue.record("expected .clef hit, got \(String(describing: target))")
            return
        }
        if case .staffDefault = anchor { /* OK */ }
        else { Issue.record("expected .staffDefault anchor, got \(anchor)") }
    }

    @Test("itemID(at:) on leading clef returns .clef(...)")
    func itemIDForLeadingClef() throws {
        let (doc, _) = try loadDoc()
        let tester = ScoreHitTester(document: doc)
        let system = try #require(doc.systems.first)
        let measure = try #require(system.measures.first)
        guard case let .clef(_, origin, _) = (
            measure.elements.first { if case .clef = $0 { return true }; return false }
        ) else {
            Issue.record("no clef element")
            return
        }
        let point = CGPoint(
            x: system.origin.x + measure.origin.x + origin.x,
            y: system.origin.y + measure.origin.y + origin.y
        )
        guard case .clef = tester.itemID(at: point) else {
            Issue.record("itemID did not return .clef")
            return
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ScoreHitTesterClefTests`
Expected: FAIL — `ScoreHitTarget.clef` doesn't exist; `hitTest` doesn't dispatch to clef.

- [ ] **Step 3: Add `.clef(ClefAnchor)` to `ScoreHitTarget`**

Edit `Sources/SheetMusicUI/Selection/ScoreHitTarget.swift`. Append a new case after `.tuplet`:

```swift
public enum ScoreHitTarget: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)
    case stem(notes: [NoteID])
    case flag(notes: [NoteID])
    case beam(notes: [NoteID])
    /// Tuplet bracket / number area. Hit-target for clicking the
    /// "3" / "5" label or the bracket line that spans the tuplet.
    case tuplet(TupletID)
    /// Selectable clef glyph. Only emitted for clefs whose
    /// `LayoutElement.clef.anchor` is non-nil — continuation-system
    /// header clef restatements are not hit-targets.
    case clef(ClefAnchor)
}
```

- [ ] **Step 4: Add `hitClef` and dispatch from `hitTestMeasure`**

Edit `Sources/SheetMusicUI/Selection/ScoreHitTester.swift`. Append a clef step after the tuplet check in `hitTestMeasure` (around line 130-132):

```swift
        // 7. Clef glyph — last in the priority ladder. Header
        //    column doesn't overlap note geometry so the position
        //    is mostly cosmetic; keeping clefs last minimises
        //    disruption to the existing ladder.
        if let target = hitClef(measure: measure, base: base, point: point, sp: sp) {
            return target
        }
```

Then add the `hitClef` method (before `// MARK: - Utilities` near the bottom of the file):

```swift
    // MARK: - Clef

    /// Bounding-box hit-test for a clef glyph. Mirrors the
    /// per-clef y-offset that `drawClef` applies (treble +1 sp,
    /// bass −1 sp, C-clef 0). Returns nil for clefs without an
    /// `anchor` (i.e. continuation-system header restatements).
    private func hitClef(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat
    ) -> ScoreHitTarget? {
        let halfWidth = sp * 1.0   // glyph width ≈ 2 sp
        let halfHeight = sp * 2.5  // glyph height ≈ 5 sp
        for el in measure.elements {
            guard case let .clef(rawType, origin, anchor) = el,
                  let anchor
            else { continue }
            let yOffset = Self.clefYOffset(rawType: rawType, sp: sp)
            let ax = base.x + origin.x
            let ay = base.y + origin.y + yOffset
            if abs(point.x - ax) <= halfWidth,
               abs(point.y - ay) <= halfHeight
            {
                return .clef(anchor)
            }
        }
        return nil
    }

    /// y-offset applied by the renderer for `rawType`. Kept in
    /// sync with `ScoreLayerBuilder.drawClef`'s switch.
    private static func clefYOffset(
        rawType: String, sp: CGFloat
    ) -> CGFloat {
        switch NotatedClef(rawType: rawType) {
        case .treble, .treble8va, .treble8vb, .treble15ma, .treble15mb:
            return sp
        case .bass, .bass8va, .bass8vb:
            return -sp
        case .alto, .tenor, .percussion:
            return 0
        }
    }
```

- [ ] **Step 5: Extend `itemID(at:)` to forward the clef target**

Edit `Sources/SheetMusicUI/Selection/ScoreHitTester.swift:86-93`:

```swift
    public func itemID(at point: CGPoint) -> ScoreItemID? {
        switch hitTest(at: point) {
        case let .note(id): return .note(id)
        case let .rest(id): return .rest(id)
        case let .tuplet(id): return .tuplet(id)
        case let .clef(anchor): return .clef(anchor)
        default: return nil
        }
    }
```

- [ ] **Step 6: Add a public `clefHitRect(for:)` accessor for popover anchoring**

Append to `ScoreHitTester` (just before the closing brace of the struct):

```swift
    /// Document-coord rectangle of the clef glyph identified by
    /// `anchor`. Returns nil when no layout element matches —
    /// e.g. after a re-layout invalidates the anchor.
    public func clefHitRect(for anchor: ClefAnchor) -> CGRect? {
        let sp = document.metrics.sp
        for system in document.systems {
            for measure in system.measures {
                let base = CGPoint(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y
                )
                for el in measure.elements {
                    guard case let .clef(rawType, origin, elAnchor) = el,
                          elAnchor == anchor
                    else { continue }
                    let yOffset = Self.clefYOffset(
                        rawType: rawType, sp: sp)
                    let centerX = base.x + origin.x
                    let centerY = base.y + origin.y + yOffset
                    return CGRect(
                        x: centerX - sp,
                        y: centerY - sp * 2.5,
                        width: sp * 2,
                        height: sp * 5
                    )
                }
            }
        }
        return nil
    }
```

- [ ] **Step 7: Run the new tests + full suite**

Run: `swift test --filter ScoreHitTesterClefTests`
Expected: PASS (2 tests).

Run: `swift test`
Expected: full suite green.

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicUI/Selection/ScoreHitTarget.swift \
        Sources/SheetMusicUI/Selection/ScoreHitTester.swift \
        Tests/SheetMusicTests/ScoreHitTesterClefTests.swift
git commit -m "ui: hit-test clefs and expose ClefAnchor lookup"
```

---

## Task 6: Tint selected clef glyph

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Notation.swift:15-43`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift:28-32`

This task plumbs the existing selection-tint pipeline through `LayoutElement.clef` so a `.single(.clef(...))` selection visually highlights the glyph. There is no unit test for tint colour here — the rendering is verified in the manual macOS smoke test (Task 9).

- [ ] **Step 1: Add a `tint` parameter to `drawClef`**

Edit `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Notation.swift:15-43`:

```swift
    static func drawClef(
        rawType: String, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        tint: CGColor? = nil,
        into parent: CALayer
    ) {
        let clef = NotatedClef(rawType: rawType)
        let glyph: Character
        let yOffset: CGFloat
        switch clef {
        case .treble: glyph = SMuFLGlyph.gClef; yOffset = metrics.sp
        case .treble8va: glyph = SMuFLGlyph.gClef8va; yOffset = metrics.sp
        case .treble8vb: glyph = SMuFLGlyph.gClef8vb; yOffset = metrics.sp
        case .treble15ma: glyph = SMuFLGlyph.gClef15ma; yOffset = metrics.sp
        case .treble15mb: glyph = SMuFLGlyph.gClef15mb; yOffset = metrics.sp
        case .bass: glyph = SMuFLGlyph.fClef; yOffset = -metrics.sp
        case .bass8va: glyph = SMuFLGlyph.fClef8va; yOffset = -metrics.sp
        case .bass8vb: glyph = SMuFLGlyph.fClef8vb; yOffset = -metrics.sp
        case .alto, .tenor: glyph = SMuFLGlyph.cClef; yOffset = 0
        case .percussion: glyph = SMuFLGlyph.percussionClef; yOffset = 0
        }
        if let layer = glyphLayer(
            glyph,
            at: CGPoint(x: origin.x, y: origin.y + yOffset),
            size: metrics.glyphFontSize,
            color: tint ?? inkColor,
            height: height
        ) {
            parent.addSublayer(layer)
        }
    }
```

- [ ] **Step 2: Pass selection tint from the dispatcher**

Edit `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift:28-32`:

```swift
        case let .clef(raw, p, anchor):
            let tint: CGColor? = {
                guard let anchor else { return nil }
                let voice: Int = {
                    if case let .explicit(veID) = anchor {
                        return veID.voiceIndex
                    }
                    return 0
                }()
                return context.selection.color(
                    for: .clef(anchor), voiceIndex: voice)
            }()
            drawClef(
                rawType: raw, origin: shift(p),
                metrics: metrics, height: height,
                tint: tint, into: parent
            )
```

> If `BuildContext.selection` is named differently, use the
> `voiceIndex`-based color lookup that the existing chord/rest
> branches already use as a template — `BuildContext` exposes
> `selection: SelectionRenderState` consistently across rendered
> element types. Confirm by reading the surrounding `drawElement`
> body before applying.

- [ ] **Step 3: Build and run tests**

Run: `swift build && swift test`
Expected: success, no regressions.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Notation.swift \
        Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift
git commit -m "ui: tint clef glyph when its anchor is selected"
```

---

## Task 7: `ClefPopover` SwiftUI view + `ClefChoice` enum

**Files:**
- Create: `Example/SheetMusicExample/macOS/ClefPopover.swift`

- [ ] **Step 1: Implement `ClefChoice` and `ClefPopover`**

Create `Example/SheetMusicExample/macOS/ClefPopover.swift`:

```swift
#if os(macOS)
    import SheetMusicUI
    import SwiftUI

    /// The four user-facing clef choices in the macOS example.
    /// The library still accepts any raw clef string via
    /// `Clef(concertClefType:)`; this enum just constrains the UI.
    enum ClefChoice: Hashable, CaseIterable {
        case trebleG, trebleG8vb, bassF, bassF8vb

        var rawType: String {
            switch self {
            case .trebleG: return "G"
            case .trebleG8vb: return "G8vb"
            case .bassF: return "F"
            case .bassF8vb: return "F8vb"
            }
        }

        var smuflGlyph: Character {
            switch self {
            case .trebleG: return SMuFLGlyph.gClef
            case .trebleG8vb: return SMuFLGlyph.gClef8vb
            case .bassF: return SMuFLGlyph.fClef
            case .bassF8vb: return SMuFLGlyph.fClef8vb
            }
        }

        static func from(rawType: String) -> ClefChoice? {
            ClefChoice.allCases.first { $0.rawType == rawType }
        }
    }

    /// 2×2 grid of clef glyph buttons used by the macOS example to
    /// replace a tapped clef. Library-level types stay format-agnostic
    /// — this view is a host-side UI choice.
    struct ClefPopover: View {
        let current: ClefChoice?
        let onPick: (ClefChoice) -> Void

        var body: some View {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    button(for: .trebleG)
                    button(for: .trebleG8vb)
                }
                HStack(spacing: 8) {
                    button(for: .bassF)
                    button(for: .bassF8vb)
                }
            }
            .padding(12)
            .frame(width: 160)
        }

        @ViewBuilder
        private func button(for choice: ClefChoice) -> some View {
            Button { onPick(choice) } label: {
                Text(String(choice.smuflGlyph))
                    .font(.custom(BravuraFont.familyName, size: 36))
                    .frame(width: 60, height: 60)
                    .background(
                        choice == current
                            ? Color.accentColor.opacity(0.18)
                            : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                choice == current
                                    ? Color.accentColor
                                    : Color.gray.opacity(0.3),
                                lineWidth: choice == current ? 2 : 1))
            }
            .buttonStyle(.plain)
            .help(choice.rawType)
        }
    }
#endif
```

> If `BravuraFont.familyName` is not exposed publicly from
> `SheetMusicUI`, either (a) add a `public` re-export there, or
> (b) hard-code `"Bravura"` (the SMuFL family name) — pick whichever
> matches the rest of the example app's font usage.
> Likewise, if `SMuFLGlyph` is not public, expose those four
> static properties via a small public surface in `SheetMusicUI`
> (e.g. `public extension SMuFLGlyph`).

- [ ] **Step 2: Verify the example app still compiles via xcodegen**

```bash
cd Example && xcodegen generate
```

Run from package root:

```bash
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=macOS' \
           -skipPackagePluginValidation build
```

Expected: build succeeds. (No runtime check — Task 8 wires the popover into `ContentViewMac`.)

- [ ] **Step 3: Commit**

```bash
git add Example/SheetMusicExample/macOS/ClefPopover.swift
# (project.yml unchanged — sources are auto-detected)
git commit -m "example(mac): add ClefPopover view and ClefChoice enum"
```

---

## Task 8: Wire popover into `ContentViewMac`

**Files:**
- Modify: `Example/SheetMusicExample/macOS/ContentViewMac.swift`

The work splits into four edits:
1. Add `ClefPopoverState` struct and `@State private var clefPopover`.
2. In `handleTap(at:document:)` (line 2448), branch on a clef hit before the existing primary-id resolution.
3. Add `applyClefChoice(_:for:)` helper.
4. Attach a SwiftUI `.popover(item:)` to the score container view that hosts the popover.

- [ ] **Step 1: Add state**

Find the block of `@State` declarations near line 50 (after `@State private var selection: ScoreSelection = .none`). Add:

```swift
        @State private var clefPopover: ClefPopoverState?

        struct ClefPopoverState: Equatable, Identifiable {
            let anchor: ClefAnchor
            let currentRawType: String
            /// Document-coord rect of the clef glyph; the SwiftUI
            /// `.popover` anchors against this via a tracking
            /// preference key on the score view.
            let attachmentRect: CGRect

            var id: ClefAnchor { anchor }
        }
```

> `ClefAnchor` is in `SheetMusicCore` — the file's existing
> `import SheetMusicCore` covers it.

- [ ] **Step 2: Add a clef-hit branch in `handleTap`**

Edit `Example/SheetMusicExample/macOS/ContentViewMac.swift` inside `handleTap(at:document:)`. After `let target = tester.hitTest(at: location)` (around line 2450) and before the playback-seek branch, insert:

```swift
            // Clef tap — open the popover instead of falling through
            // to the regular selection ladder. Skip while playing so
            // tap-to-seek behaves the same for clefs as for notes.
            if playbackEngine.state != .playing,
               case let .clef(anchor) = target
            {
                let raw = currentClefRawType(for: anchor) ?? "G"
                let rect = tester.clefHitRect(for: anchor)
                    ?? CGRect(x: location.x - 12, y: location.y - 24,
                              width: 24, height: 48)
                clefPopover = ClefPopoverState(
                    anchor: anchor,
                    currentRawType: raw,
                    attachmentRect: rect)
                selection = .single(.clef(anchor))
                return
            }
```

Find a quiet spot in the same struct (e.g. just below `handleTap`) and add the helper:

```swift
        private func currentClefRawType(for anchor: ClefAnchor) -> String? {
            guard let score else { return nil }
            switch anchor {
            case let .explicit(veID):
                if case let .clef(c) = score[veID] {
                    return c.concertClefType
                }
                return nil
            case let .staffDefault(staff):
                return score[staff]?.defaultClefType
            }
        }
```

Also extend the existing `switch target` (around line 2490, the one that resolves to `primary`) so the new case compiles. Add a `case .clef:` arm at the bottom that simply returns (the clef-hit branch above already handled the case, but the exhaustive switch needs an arm):

```swift
            case .clef:
                // Already handled above; this arm keeps the
                // switch exhaustive.
                return
```

- [ ] **Step 3: Add `applyClefChoice` helper**

Place it near the other edit helpers (e.g. close to `applyDurationChange`):

```swift
        private func applyClefChoice(
            _ choice: ClefChoice, for anchor: ClefAnchor
        ) {
            guard let controller = inputController else { return }
            do {
                switch anchor {
                case let .explicit(veID):
                    let newClef = Clef(concertClefType: choice.rawType)
                    try controller.apply(
                        ReplaceVoiceElement(
                            at: veID,
                            with: .clef(newClef)),
                        undoManager: undoManager)
                case let .staffDefault(staff):
                    try controller.apply(
                        SetStaffDefaultClef(
                            staff: staff,
                            newRawType: choice.rawType),
                        undoManager: undoManager)
                }
            } catch {
                errorMessage = "Failed to change clef: " +
                    error.localizedDescription
            }
            clefPopover = nil
            selection = .none
        }
```

> If the file doesn't yet import the editing types, the existing
> `import SheetMusicCore` covers `ReplaceVoiceElement` and
> `SetStaffDefaultClef`.

- [ ] **Step 4: Attach the popover to the score container**

Find the `body` of `ContentViewMac` (search for the outermost `var body: some View`). The score container is rendered via `currentLayoutView(score:)` (or similar — look at what is wrapped by the toolbar). Wrap it with the popover:

```swift
            currentLayoutView(score: score)
                .popover(item: $clefPopover, arrowEdge: .top) { state in
                    ClefPopover(
                        current: ClefChoice.from(rawType: state.currentRawType)
                    ) { choice in
                        applyClefChoice(choice, for: state.anchor)
                    }
                }
```

> SwiftUI `.popover(item:)` positions itself off the view it's attached to. Anchoring it
> exactly to `attachmentRect` would require a `PreferenceKey`-based
> tracker on the score view; that is out of scope for the spec.
> The popover appearing centred over the score container is
> acceptable for this milestone — the spec only requires that the
> popover open and the selection highlight indicate which clef is
> active.

- [ ] **Step 5: Regenerate the Xcode project and build**

```bash
cd Example && xcodegen generate
```

```bash
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=macOS' \
           -skipPackagePluginValidation build
```

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Example/SheetMusicExample/macOS/ContentViewMac.swift
git commit -m "example(mac): wire clef tap → popover → edit dispatch"
```

---

## Task 9: Final validation

- [ ] **Step 1: Run the full SwiftPM test suite**

```bash
swift test
```

Expected: 100% green.

- [ ] **Step 2: SwiftLint clean**

```bash
swiftlint --quiet Sources Tests
```

Expected: 0 warnings/errors. (If the new files exceed the 300-line cap, split per the existing `+Foo.swift` convention.)

- [ ] **Step 3: Manual macOS smoke test**

Hand off to the user with these reproducible steps:

1. Build & run `SheetMusicExample` for `platform=macOS`.
2. Open a sample with two staves (the bundled `midi05.mscx` works).
3. Click the leading G clef on the top staff → popover appears with a 2×2 grid; the highlighted button matches the current clef.
4. Click the "F" tile → glyph re-renders as a bass clef.
5. ⌘Z → reverts to G clef.
6. Open a fixture with a mid-piece explicit clef change (any sample with `<Clef>` mid-staff) and repeat 3–5 on that clef.
7. With multiple systems wrapped, click a continuation-system header clef → no popover, no selection change.

Document any deviation in the commit body for Task 9.

- [ ] **Step 4: Final commit (only if any cleanup was needed)**

```bash
git status        # confirm tree is clean
```

If clean, no further commit. The branch is ready for review.

- [ ] **Step 5: Open QuickMD for the spec + plan (per global preference)**

```bash
quick-md docs/superpowers/specs/2026-05-10-clef-selection-and-replace-design.md
quick-md docs/superpowers/plans/2026-05-10-clef-selection-and-replace.md
```

(Already done at spec-write time for the spec; only re-open if the plan changed in this session.)
