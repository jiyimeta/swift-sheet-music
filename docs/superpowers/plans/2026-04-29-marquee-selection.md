# Marquee Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an O(log N + k) marquee/rect query (`ScoreHitTester.itemIDs(in:)`) backed by a precomputed `LayoutSystem.eventColumns` index, plus a `ScoreSelection.multi(Set<ScoreItemID>)` case that the iOS Example wires up via a toolbar-toggled drag-rectangle gesture.

**Architecture:** Three layers, bottom-up. (1) `LayoutSystem` stores an X-sorted `[EventColumn]` derived from its measures' `.chord` / `.rest` elements at init time. (2) `ScoreHitTester.itemIDs(in:)` uses Y-band prefilter + binary search on `centerX` + bbox intersection to return ids in visit order. (3) `ScoreSelection.multi` is an arbitrary set the renderer treats like multiple `.single` highlights, no range-box overlay. The Example app gates the marquee gesture behind a toolbar toggle so it never collides with tap/scroll.

**Tech Stack:** Swift Package Manager, Swift Testing (`import Testing`), SwiftUI (iOS), `LayoutEngine` from `SheetMusicLayout`, `ScoreHitTester` from `SheetMusicUI`.

---

## Spec reference

`docs/superpowers/specs/2026-04-29-marquee-selection-design.md`. Read it before starting any task.

## File map

New library files:
- `Sources/SheetMusicLayout/Layout/EventColumn.swift` — value type + index-build helper.
- `Tests/SheetMusicTests/LayoutSystemEventColumnsTests.swift` — invariants for the precomputed index.

Modified library files:
- `Sources/SheetMusicLayout/Layout/LayoutSystem.swift` — store `eventColumns` + `maxBBoxHalfWidth`; init computes them from `measures`.
- `Sources/SheetMusicUI/Selection/ScoreHitTester.swift` — add `itemIDs(in:)` and a private rect-query helper.
- `Sources/SheetMusicUI/Selection/ScoreSelection.swift` — add `.multi(Set<ScoreItemID>)`.
- `Sources/SheetMusicUI/Selection/SelectionRenderState.swift` — handle `.multi` case.
- `Tests/SheetMusicTests/ScoreHitTesterTests.swift` — add `itemIDs(in:)` cases.

New Example files (iOS):
- `Example/SheetMusicExample/iOS/MarqueeOverlay.swift` — SwiftUI overlay drawing the live rectangle + dashed stroke during a drag.

Modified Example files:
- `Example/SheetMusicExample/ContentView.swift` — `@State` toggle, toolbar button, vertical-mode `.overlay` + `DragGesture`, drag-end → `.multi(...)`.

## Conventions reminders

- Swift Testing: `import Testing`; `@Suite`, `@Test`, `#expect`, `#require`. NOT XCTest.
- `@testable import SheetMusicCore` / `SheetMusicLayout` / `SheetMusicUI` — re-exports do NOT transitively grant testable access.
- File length cap (SwiftLint): 300 lines. If a file approaches it, split via extension files (`+Foo.swift` pattern).
- `LayoutSystem`/`LayoutMeasure`/`ScoreHitTester` are `@available(macOS 15.0, iOS 16.0, *)`. New types in the same modules MUST carry the same availability annotation.
- The Example iOS file is wrapped in `#if !os(macOS)` … `#endif`. Anything you add stays inside that block.
- Run: `swift build` after every step that adds a type; `swift test` after every step that touches test code.

---

## Task 1: Define `EventColumn`

**Files:**
- Create: `Sources/SheetMusicLayout/Layout/EventColumn.swift`

- [ ] **Step 1: Write the new file**

```swift
import CoreGraphics
import SheetMusicCore

/// One chord/rest anchor in a `LayoutSystem`, precomputed for
/// rect-range queries (`ScoreHitTester.itemIDs(in:)`) and future
/// nearest-X lookups. Coordinates are **system-relative** (same
/// space as `LayoutSystem.measures[*].elements[*]` after applying
/// the measure origin).
@available(macOS 15.0, iOS 16.0, *)
public struct EventColumn: Sendable, Equatable {
    public let id: ScoreItemID
    public let voiceIndex: Int
    public let centerX: CGFloat
    public let centerY: CGFloat
    /// System-relative bbox used for rect-intersection tests.
    /// For chords this is the union of notehead rects; for rests
    /// it's the rest glyph rect (matches `ScoreHitTester.hitRest`'s
    /// half-extents: 1.8 sp × 2.5 sp around `origin`).
    public let bbox: CGRect

    public init(
        id: ScoreItemID,
        voiceIndex: Int,
        centerX: CGFloat,
        centerY: CGFloat,
        bbox: CGRect
    ) {
        self.id = id
        self.voiceIndex = voiceIndex
        self.centerX = centerX
        self.centerY = centerY
        self.bbox = bbox
    }
}
```

- [ ] **Step 2: Verify compile**

Run: `swift build`
Expected: compiles cleanly (no consumers yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/EventColumn.swift
git commit -m "layout: add EventColumn value type for chord/rest indexing"
```

---

## Task 2: Precompute `eventColumns` on `LayoutSystem`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutSystem.swift`
- Test: `Tests/SheetMusicTests/LayoutSystemEventColumnsTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/LayoutSystemEventColumnsTests.swift`:

```swift
import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutSystem.eventColumns")
struct LayoutSystemEventColumnsTests {
    private func sample() -> Score {
        let chord = { (p: Int) -> VoiceElement in
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: p, tpc: 14)]))
        }
        let measure = Measure(voices: [
            Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                chord(60), .rest(Rest(duration: .quarter)),
                chord(64), chord(65)
            ])
        ])
        return Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "piano", longName: "Piano"),
                staffDeclarations: [StaffDeclaration(
                    staffType: "stdNormal",
                    group: "pitched",
                    defaultClefType: "G")])],
            staves: [StaffContent(id: 1, measures: [measure])])
    }

    @Test("Index has one entry per chord + rest, sorted by centerX")
    func indexShapeAndOrder() throws {
        guard #available(macOS 15.0, *) else { return }
        let doc = LayoutEngine.layout(
            score: sample(),
            options: ScoreViewOptions(),
            availableWidth: 600)
        let system = try #require(doc.systems.first)

        // 3 chords + 1 rest from `sample()`, no clef entry.
        #expect(system.eventColumns.count == 4)
        let xs = system.eventColumns.map(\.centerX)
        #expect(xs == xs.sorted())

        // Each entry's id matches a chord/rest in the underlying
        // measure layout.
        let kinds = Set(system.eventColumns.map { col -> String in
            switch col.id {
            case .note: return "note"
            case .rest: return "rest"
            }
        })
        #expect(kinds == ["note", "rest"])
    }

    @Test("maxBBoxHalfWidth is the max of all column bboxes")
    func maxBBoxHalfWidthInvariant() throws {
        guard #available(macOS 15.0, *) else { return }
        let doc = LayoutEngine.layout(
            score: sample(),
            options: ScoreViewOptions(),
            availableWidth: 600)
        let system = try #require(doc.systems.first)

        let expected = system.eventColumns
            .map { $0.bbox.width / 2 }
            .max() ?? 0
        #expect(abs(system.maxBBoxHalfWidth - expected) < 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LayoutSystemEventColumnsTests`
Expected: FAIL — `eventColumns` and `maxBBoxHalfWidth` don't exist on `LayoutSystem`.

- [ ] **Step 3: Add the stored properties + computation to `LayoutSystem`**

Edit `Sources/SheetMusicLayout/Layout/LayoutSystem.swift`:

```swift
import CoreGraphics
import SheetMusicCore

/// One horizontal line of music. Contains one or more staves stacked
/// vertically and one or more parts.
@available(macOS 15.0, iOS 16.0, *)
public struct LayoutSystem: Sendable, Equatable {
    public let origin: CGPoint       // in document coordinates
    public let size: CGSize
    public let measures: [LayoutMeasure]
    /// Per-staff baselines (top-left in system coordinates).
    public let staffOrigins: [CGPoint]
    /// Part labels at the left edge of this system (empty on continuation
    /// systems per MuseScore convention).
    public let partLabels: [LayoutPartLabel]
    /// Cross-measure spanner segments (slurs, voltas, hairpins, etc.)
    /// resolved after measure placement. Origins are in system coords.
    public let spanners: [LayoutElement]
    /// Chord/rest anchors of every measure flattened into one
    /// X-sorted index. Built deterministically from `measures` —
    /// callers MUST NOT supply a divergent value via `init`.
    /// Drives `ScoreHitTester.itemIDs(in:)` (marquee) and is the
    /// substrate for future O(log N) nearest-X lookups.
    public let eventColumns: [EventColumn]
    /// Largest `eventColumns[i].bbox.width / 2`, or 0 when empty.
    /// Used as the binary-search tolerance so a rect that intersects
    /// an event's bbox but lies outside its `centerX` still hits.
    public let maxBBoxHalfWidth: CGFloat

    public init(
        origin: CGPoint,
        size: CGSize,
        measures: [LayoutMeasure],
        staffOrigins: [CGPoint],
        partLabels: [LayoutPartLabel],
        spanners: [LayoutElement]
    ) {
        self.origin = origin
        self.size = size
        self.measures = measures
        self.staffOrigins = staffOrigins
        self.partLabels = partLabels
        self.spanners = spanners
        let columns = Self.buildEventColumns(measures: measures)
        self.eventColumns = columns
        self.maxBBoxHalfWidth = columns
            .map { $0.bbox.width / 2 }
            .max() ?? 0
    }

    private static func buildEventColumns(
        measures: [LayoutMeasure]
    ) -> [EventColumn] {
        // Match the same per-glyph extents `ScoreHitTester` uses so
        // bbox-intersection at query time agrees with single-tap
        // hit-test radii (see `ScoreHitTester.hitNote` / `hitRest`).
        // The constants here are sp-multiples baked at layout time;
        // we approximate with conservative absolute values because
        // `LayoutSystem` doesn't carry `sp`. Document metrics live on
        // `LayoutDocument`; the tester applies the rect against
        // system-relative bbox so coords match.
        // For the chord case we use the union of notehead origins
        // expanded by `noteRadius` (1.2 sp) — but since `sp` isn't
        // available here, we fall back to a fixed ratio of the
        // notehead gap. Use `noteHalfExtent` = `chord.notes`' x-spread
        // plus a margin that mirrors the tester.
        var result: [EventColumn] = []
        for measure in measures {
            let mx = measure.origin.x
            let my = measure.origin.y
            for el in measure.elements {
                switch el {
                case .chord(let notes, _, _, _, _, _, _, let voiceIndex):
                    guard !notes.isEmpty else { continue }
                    let xs = notes.map { mx + $0.origin.x }
                    let ys = notes.map { my + $0.origin.y }
                    guard let minX = xs.min(),
                          let maxX = xs.max(),
                          let minY = ys.min(),
                          let maxY = ys.max(),
                          let topNote = notes.min(by: {
                              $0.origin.y < $1.origin.y })
                    else { continue }
                    // Notehead radius = 0.6 staff-line gaps ≈ 4.2 pt at
                    // default 14 pt staff. Conservative absolute pad
                    // keeps bbox aligned with the tester's `sp * 1.2`
                    // hit radius for typical staff sizes.
                    let pad: CGFloat = 4.5
                    let bbox = CGRect(
                        x: minX - pad,
                        y: minY - pad,
                        width: (maxX - minX) + pad * 2,
                        height: (maxY - minY) + pad * 2)
                    result.append(EventColumn(
                        id: .note(topNote.noteID),
                        voiceIndex: voiceIndex,
                        centerX: (minX + maxX) / 2,
                        centerY: (minY + maxY) / 2,
                        bbox: bbox))
                case .rest(_, let origin, let voiceIndex, let restID, _):
                    let cx = mx + origin.x
                    let cy = my + origin.y
                    let halfW: CGFloat = 6.5      // ≈ 1.8 sp at sp=3.5
                    let halfH: CGFloat = 9.0      // ≈ 2.5 sp at sp=3.5
                    let bbox = CGRect(
                        x: cx - halfW, y: cy - halfH,
                        width: halfW * 2, height: halfH * 2)
                    result.append(EventColumn(
                        id: .rest(restID),
                        voiceIndex: voiceIndex,
                        centerX: cx,
                        centerY: cy,
                        bbox: bbox))
                default:
                    continue
                }
            }
        }
        result.sort { $0.centerX < $1.centerX }
        return result
    }
}

@available(macOS 15.0, iOS 16.0, *)
public struct LayoutPartLabel: Sendable, Equatable {
    public let text: String
    public let origin: CGPoint

    public init(text: String, origin: CGPoint) {
        self.text = text
        self.origin = origin
    }
}
```

Note: existing `LayoutSystem(...)` call sites (`LayoutEngine.swift`, `+Contexts`, `+Ties`, `+Spanners`, `+SystemBuild`, plus 2 test files) keep their argument lists identical — `eventColumns` and `maxBBoxHalfWidth` are derived inside the init.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter LayoutSystemEventColumnsTests`
Expected: PASS (both cases).

- [ ] **Step 5: Run full suite to verify nothing regresses**

Run: `swift test`
Expected: all 231 tests pass (229 prior + 2 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutSystem.swift Tests/SheetMusicTests/LayoutSystemEventColumnsTests.swift
git commit -m "layout: precompute LayoutSystem.eventColumns + maxBBoxHalfWidth"
```

---

## Task 3: Add `ScoreSelection.multi` case

**Files:**
- Modify: `Sources/SheetMusicUI/Selection/ScoreSelection.swift`
- Modify: `Sources/SheetMusicUI/Selection/SelectionRenderState.swift`

- [ ] **Step 1: Add the new case**

Edit `Sources/SheetMusicUI/Selection/ScoreSelection.swift`:

```swift
import SheetMusicCore
import SheetMusicLayout

/// Current selection state passed to `ScoreView` for highlight rendering.
///
/// - `.none`: no notes are highlighted and no range box is drawn.
/// - `.single(NoteID)`: one note is highlighted (no range box).
/// - `.range(anchor:target:)`: every note in the rectangular region
///   bounded by `anchor` and `target` (staff × time) is highlighted,
///   and a coloured box outlines the region on each system it crosses.
/// - `.multi(Set<ScoreItemID>)`: an arbitrary set of items is
///   highlighted (no range box). Used for marquee / lasso selections
///   where the picked items don't form a contiguous time window.
public enum ScoreSelection: Sendable, Equatable {
    case none
    case single(ScoreItemID)
    case range(anchor: ScoreItemID, target: ScoreItemID)
    case multi(Set<ScoreItemID>)
}
```

- [ ] **Step 2: Run build to surface non-exhaustive switches**

Run: `swift build`
Expected: at least one compile error in `SelectionRenderState.make` for unhandled `.multi`. Note the exact error location.

- [ ] **Step 3: Handle `.multi` in `SelectionRenderState`**

Edit `Sources/SheetMusicUI/Selection/SelectionRenderState.swift`, in the `static func make` switch, add the new case BEFORE the closing brace of the switch:

```swift
        case let .multi(ids):
            return SelectionRenderState(
                selectedIDs: ids,
                voiceColors: cgColors,
                drawRangeBox: false,
                rangeBoxColor: defaultBoxColor)
```

- [ ] **Step 4: Build to verify exhaustiveness**

Run: `swift build`
Expected: compiles cleanly.

- [ ] **Step 5: Run full suite**

Run: `swift test`
Expected: all tests still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicUI/Selection/ScoreSelection.swift Sources/SheetMusicUI/Selection/SelectionRenderState.swift
git commit -m "ui: add ScoreSelection.multi for arbitrary-set highlights"
```

---

## Task 4: `ScoreHitTester.itemIDs(in:)`

**Files:**
- Modify: `Sources/SheetMusicUI/Selection/ScoreHitTester.swift`
- Test: `Tests/SheetMusicTests/ScoreHitTesterTests.swift` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SheetMusicTests/ScoreHitTesterTests.swift` (inside the existing `@Suite("ScoreHitTester") struct ScoreHitTesterTests { … }` block, before the closing brace):

```swift
    @Test("itemIDs(in:) returns events whose bbox intersects the rect")
    func marqueeBasic() throws {
        guard #available(macOS 15.0, *) else { return }
        let score = sample()
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(),
            availableWidth: 600)
        let tester = ScoreHitTester(document: doc)

        // Rect that covers the whole first system.
        let system = try #require(doc.systems.first)
        let allRect = CGRect(
            x: system.origin.x,
            y: system.origin.y,
            width: system.size.width,
            height: system.size.height)
        let allIds = tester.itemIDs(in: allRect)
        // 3 chords + 1 rest from sample().
        #expect(allIds.count == 4)
    }

    @Test("itemIDs(in:) misses events outside the rect")
    func marqueeEmpty() throws {
        guard #available(macOS 15.0, *) else { return }
        let score = sample()
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(),
            availableWidth: 600)
        let tester = ScoreHitTester(document: doc)
        // Rect far below the system.
        let rect = CGRect(x: 0, y: 100_000, width: 10, height: 10)
        #expect(tester.itemIDs(in: rect).isEmpty)
    }

    @Test("itemIDs(in:) preserves visit order (sorted by centerX)")
    func marqueeOrder() throws {
        guard #available(macOS 15.0, *) else { return }
        let score = sample()
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(),
            availableWidth: 600)
        let tester = ScoreHitTester(document: doc)

        let system = try #require(doc.systems.first)
        let allRect = CGRect(
            x: system.origin.x, y: system.origin.y,
            width: system.size.width, height: system.size.height)
        let ids = tester.itemIDs(in: allRect)
        // Resolve each id back to its centerX via system.eventColumns
        // and verify they're in ascending order.
        let xs: [CGFloat] = ids.compactMap { id in
            system.eventColumns.first(where: { $0.id == id })
                .map { $0.centerX + system.origin.x }
        }
        #expect(xs == xs.sorted())
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ScoreHitTesterTests`
Expected: FAIL — `itemIDs(in:)` doesn't exist.

- [ ] **Step 3: Implement `itemIDs(in:)`**

Add to `Sources/SheetMusicUI/Selection/ScoreHitTester.swift`, inside `public struct ScoreHitTester { … }`, after the existing `itemID(at:)` method (around line 89):

```swift
    /// All chord/rest ids whose layout bbox intersects `rect`
    /// (in `LayoutDocument` coords, same space as `hitTest(at:)`).
    /// Result preserves visit order: systems top-to-bottom, then
    /// `EventColumn.centerX` ascending within each system.
    ///
    /// O(systems_intersecting_rect · (log E + k)).
    public func itemIDs(in rect: CGRect) -> [ScoreItemID] {
        var result: [ScoreItemID] = []
        for system in document.systems {
            // Y-band prefilter: a system whose vertical extent
            // doesn't intersect `rect` contributes nothing.
            let sysMinY = system.origin.y
            let sysMaxY = sysMinY + system.size.height
            guard sysMaxY >= rect.minY,
                  sysMinY <= rect.maxY
            else { continue }

            let columns = system.eventColumns
            guard !columns.isEmpty else { continue }
            // Translate query rect into system-relative coords for
            // bbox tests (which are stored system-relative).
            let localRect = rect.offsetBy(
                dx: -system.origin.x, dy: -system.origin.y)
            let tol = system.maxBBoxHalfWidth

            // Binary-search the X window: skip columns whose
            // (centerX + tol) is still left of localRect.minX.
            let lo = lowerBoundCenterX(
                columns: columns,
                value: localRect.minX - tol)
            let hi = upperBoundCenterX(
                columns: columns,
                value: localRect.maxX + tol)
            guard lo < hi else { continue }

            for i in lo..<hi {
                let col = columns[i]
                if col.bbox.intersects(localRect) {
                    result.append(col.id)
                }
            }
        }
        return result
    }

    /// First index in `columns` whose `centerX >= value`. Returns
    /// `columns.count` if none exists.
    private func lowerBoundCenterX(
        columns: [EventColumn], value: CGFloat
    ) -> Int {
        var lo = 0
        var hi = columns.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if columns[mid].centerX < value {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// First index in `columns` whose `centerX > value`. Returns
    /// `columns.count` if all are `<= value`.
    private func upperBoundCenterX(
        columns: [EventColumn], value: CGFloat
    ) -> Int {
        var lo = 0
        var hi = columns.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if columns[mid].centerX <= value {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ScoreHitTesterTests`
Expected: all ScoreHitTester tests pass (existing + new 3).

- [ ] **Step 5: Run full suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 6: SwiftLint check (optional but matches project convention)**

Run: `swiftlint --quiet Sources Tests` (skip if `swiftlint` not installed).
Expected: 0 warnings/errors. If `ScoreHitTester.swift` exceeds 300 lines, split the new methods into `ScoreHitTester+Marquee.swift` extension file.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicUI/Selection/ScoreHitTester.swift Tests/SheetMusicTests/ScoreHitTesterTests.swift
git commit -m "ui: ScoreHitTester.itemIDs(in:) marquee query via eventColumns"
```

---

## Task 5: iOS Example — Marquee toggle state + toolbar button

**Files:**
- Modify: `Example/SheetMusicExample/ContentView.swift`

- [ ] **Step 1: Add `@State` for marquee mode + active drag rect**

In `ContentView.swift`, after `@State private var isMixerPresented = false` (around line 71), add:

```swift
    /// When true, vertical-mode drags become marquee selections
    /// instead of falling through to scroll. Toggled from the
    /// toolbar; OFF restores normal tap/scroll behaviour.
    @State private var isMarqueeMode = false
    /// Active marquee rectangle in vertical-mode local coords.
    /// `nil` outside an in-progress drag; the overlay reads this
    /// to draw the live selection rectangle.
    @State private var marqueeRect: CGRect?
```

- [ ] **Step 2: Add the toolbar toggle**

Inside the trailing toolbar `Menu { … }` (around line 168, BEFORE the existing `Divider()` that precedes the zoom buttons), insert:

```swift
                        Toggle(isOn: $isMarqueeMode) {
                            Label("Marquee Select",
                                systemImage: "rectangle.dashed")
                        }
                        .disabled(score == nil
                            || layoutMode != .vertical)

                        Divider()
```

(Keep the existing `Divider()` that was already there — there will be two dividers around this group, which matches SwiftUI Menu conventions for grouped toggles.)

- [ ] **Step 3: Build (the iOS scheme via xcodegen)**

Run from repo root:

```bash
cd Example && xcodegen generate
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Example/SheetMusicExample/ContentView.swift
git commit -m "example(iOS): add marquee-mode toolbar toggle + state"
```

---

## Task 6: iOS Example — Marquee overlay component

**Files:**
- Create: `Example/SheetMusicExample/iOS/MarqueeOverlay.swift`

- [ ] **Step 1: Write the overlay view**

Create `Example/SheetMusicExample/iOS/MarqueeOverlay.swift`:

```swift
#if !os(macOS)
import SwiftUI

/// Translucent rectangle + dashed stroke drawn over `ScoreView`
/// while the user is dragging a marquee selection. `rect` is `nil`
/// outside an active drag, in which case nothing renders.
struct MarqueeOverlay: View {
    let rect: CGRect?

    var body: some View {
        GeometryReader { _ in
            if let rect {
                ZStack {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                    Rectangle()
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(
                                lineWidth: 1.5,
                                dash: [5, 3]))
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
            }
        }
    }
}
#endif
```

- [ ] **Step 2: Verify it compiles via the iOS build**

Run:

```bash
cd Example && xcodegen generate
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Example/SheetMusicExample/iOS/MarqueeOverlay.swift Example/project.yml
git commit -m "example(iOS): MarqueeOverlay view (translucent rect + dashed stroke)"
```

(`project.yml` may not have changed if xcodegen auto-discovers; commit only the files git status shows.)

---

## Task 7: iOS Example — Wire the drag gesture in vertical mode

**Files:**
- Modify: `Example/SheetMusicExample/ContentView.swift`

- [ ] **Step 1: Replace the vertical-mode `ScoreView` block**

In `ContentView.swift`, find the `case .vertical:` block (around line 282–324). Inside the `if let doc = verticalDoc { ZStack(...) { … } }`, the current `ScoreView` carries `.onTapGesture { … }`. Add a marquee-aware drag overlay around the `ScoreView` and gate the tap handler on `!isMarqueeMode`. Replace the inner `ZStack(alignment: .topLeading) { … }` body with:

```swift
                            ZStack(alignment: .topLeading) {
                                ScoreView(
                                    document: doc, score: score,
                                    selection: selection,
                                    voiceColors: voiceColors,
                                    playbackCursor: playbackEngine.currentCursor)
                                    .onTapGesture { loc in
                                        guard !isMarqueeMode else { return }
                                        handleTap(at: loc, document: doc)
                                    }
                                    .gesture(
                                        isMarqueeMode
                                            ? marqueeDragGesture(document: doc)
                                            : nil)
                                    .overlay(
                                        MarqueeOverlay(rect: marqueeRect))
                                VerticalSystemAnchors(document: doc)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 16)
```

- [ ] **Step 2: Add the gesture builder + drag-end handler**

Add these two private methods in `ContentView` near `handleTap` (around line 513):

```swift
    /// Drag gesture used while marquee mode is on. Uses
    /// `minimumDistance: 0` so a tap+release with no movement still
    /// resolves (clears selection if no events fall in the zero
    /// rect). Coordinates are reported in the gesture's local space,
    /// which matches the `ZStack`'s coordinate system — same space
    /// as `LayoutDocument` because the `.padding` wrappers shift the
    /// content but the gesture sits inside the padding.
    private func marqueeDragGesture(
        document: LayoutDocument
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                marqueeRect = makeRect(
                    from: value.startLocation,
                    to: value.location)
            }
            .onEnded { value in
                let rect = makeRect(
                    from: value.startLocation,
                    to: value.location)
                marqueeRect = nil
                applyMarquee(rect: rect, document: document)
            }
    }

    private func makeRect(
        from a: CGPoint, to b: CGPoint
    ) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y))
    }

    private func applyMarquee(
        rect: CGRect, document: LayoutDocument
    ) {
        let tester = ScoreHitTester(document: document)
        let ids = tester.itemIDs(in: rect)
        if ids.isEmpty {
            selection = .none
        } else {
            selection = .multi(Set(ids))
        }
        // A fresh marquee selection drops the playback cursor for
        // the same reason `handleTap` does.
        playbackEngine.clearCursor()
    }
```

- [ ] **Step 3: Build and verify**

Run:

```bash
cd Example && xcodegen generate
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Example/SheetMusicExample/ContentView.swift
git commit -m "example(iOS): wire marquee drag → ScoreSelection.multi"
```

---

## Task 8: Final verification

- [ ] **Step 1: Full library test suite**

Run: `swift test`
Expected: 234 tests pass (229 prior + 2 from Task 2 + 3 from Task 4). All suites green.

- [ ] **Step 2: SwiftLint**

Run: `swiftlint --quiet Sources Tests` (skip if `swiftlint` not installed).
Expected: 0 warnings/errors. If any new file exceeds 300 lines, split into a `+Foo.swift` extension file and re-commit.

- [ ] **Step 3: macOS Example sanity build**

Run:

```bash
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExampleMac build
```

Expected: build succeeds. Marquee mode is iOS-only; macOS should be unchanged.

- [ ] **Step 4: iOS Example build**

Run:

```bash
cd Example && xcodegen generate
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: build succeeds.

- [ ] **Step 5: Hand visual verification to user**

Per memory `feedback_visual_verify_mac.md`: do NOT launch the iOS simulator yourself. Tell the user the build is ready and ask them to verify the marquee gesture in iOS Simulator. Provide the exact reproduction recipe:

> 1. Open the project in Xcode and run the iOS scheme on iPhone 17.
> 2. Toolbar overflow (•••) menu → toggle "Marquee Select" ON.
> 3. Drag a rectangle over a few notes in the vertical layout.
> 4. On release, the touched chords/rests should highlight in the voice colours; the dashed rectangle should disappear.
> 5. Drag over empty area → selection clears.
> 6. Toggle Marquee OFF → tap behaviour returns to single-note selection.

---

## Self-review checklist (filled at plan-write time)

- **Spec coverage:**
  - § 1 LayoutSystem.eventColumns + maxBBoxHalfWidth → Task 2.
  - § 2 ScoreHitTester.itemIDs(in:) → Task 4.
  - § 2 nearestItem(at:) → explicitly out-of-scope per spec ("not part of this PR").
  - § 3 ScoreSelection.multi + render mapping → Task 3.
  - § 4 iOS toolbar toggle → Task 5.
  - § 4 MarqueeOverlay → Task 6.
  - § 4 drag-end → .multi → Task 7.
  - Tests (library) — `LayoutSystemEventColumnsTests` Task 2; `ScoreHitTesterTests` extensions Task 4.
- **Placeholder scan:** no TBD/TODO/"add appropriate handling".
- **Type consistency:** `EventColumn` fields (`id`, `voiceIndex`, `centerX`, `centerY`, `bbox`) used consistently in Tasks 1, 2, 4. `LayoutSystem.eventColumns` / `maxBBoxHalfWidth` named identically across Tasks 2, 4. `ScoreSelection.multi(Set<ScoreItemID>)` signature stable across Tasks 3, 7. `ScoreHitTester.itemIDs(in:) -> [ScoreItemID]` consistent in Tasks 4, 7.
- **Risks (from spec):**
  - Exhaustiveness audit handled by Task 3 Step 2 (compile-driven).
  - `LayoutSystem.init` ergonomics resolved per spec recommendation (option a: init computes columns) in Task 2 Step 3.
  - No expected change to `ScoreSemanticComparison` — Task 8 Step 1 (full test suite) catches any regression.
