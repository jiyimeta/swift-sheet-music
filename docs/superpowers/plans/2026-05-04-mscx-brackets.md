# MSCX Brackets & Per-Part Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read MuseScore's `<bracket>` markup from `.mscx` into the Score model, render brace / normal / square / line per type, and collapse per-staff duplicate part labels into one label per Part.

**Architecture:** Three-layer change. (1) Core gains a typed `BracketItem` list on `Staff`. (2) MSCX decoder reads `<bracket>` children of `<Staff>` into that list — auto-derivation from instrument family is explicitly out of scope. (3) Layout emits one `LayoutBracket` per item with topY/bottomY/column geometry, and the renderer dispatches per `BracketType` (brace via Bravura SMuFL `U+E000`, others via stroked paths). Part labels collapse from one-per-staff to one-per-Part; `LayoutSystem.partLabels.count` becomes `score.parts.count`.

**Tech Stack:** Swift 5.10+, Swift Testing (`@Test` / `#expect`), CoreText, QuartzCore (CALayer), SwiftUI `GraphicsContext`. Bravura SMuFL font is already registered at runtime via `BravuraFont.register`.

**Reference:** `docs/superpowers/specs/2026-05-04-mscx-brackets-design.md` (full design with C++ pointers).

---

## File Structure

**New files:**
- `Sources/SheetMusicCore/Score/BracketItem.swift` — `BracketType` enum + `BracketItem` struct.
- `Tests/SheetMusicTests/BracketItemTests.swift` — Core type tests (clamping, defaults).
- `Tests/SheetMusicTests/BracketDecodingTests.swift` — MSCX `<bracket>` element decoding.
- `Tests/SheetMusicTests/LayoutBracketTests.swift` — `LayoutSystem.brackets` geometry.
- `Tests/SheetMusicTests/BracketRenderingTests.swift` — Layer-tree assertions for each bracket type.

**Modified files:**
- `Sources/SheetMusicCore/Score/Staff.swift` — add `brackets: [BracketItem]` property.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Staff.swift` — decode `<bracket>` children.
- `Sources/SheetMusicLayout/Layout/LayoutSystem.swift` — add `LayoutBracket` type + `brackets` field on `LayoutSystem` + init param.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift` — per-Part label collapse + bracket geometry pass.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift` — gutter width includes bracket columns.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift` — thread `brackets` through rebuild.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Ties.swift` — thread `brackets` through rebuild.
- `Sources/SheetMusicLayout/Layout/LayoutEngine.swift` — thread `brackets` through `shift`.
- `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Staves.swift` — `drawBracket` → `drawBrackets`, dispatch per type.
- `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder.swift` — call `drawBrackets`.
- `Sources/SheetMusicUI/Rendering/StaffRenderer.swift` — `drawBracket` → `drawBrackets`, dispatch per type.
- `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift` — iterate `system.brackets`.
- `Tests/SheetMusicTests/Resources/multiPartMixedStaves.mscx` — add explicit `<bracket>` elements.
- `Tests/SheetMusicTests/LayoutPartLabelClefTests.swift` — rewrite for per-Part semantics.

**Out-of-scope (spec):** Auto-derivation from instrument family (`Score::updateBracesAndBarlines`), bracket editing UI, bracket color attribute, instruments.xml bundling.

---

## Task 1: Core types — `BracketType` and `BracketItem`

**Files:**
- Create: `Sources/SheetMusicCore/Score/BracketItem.swift`
- Test: `Tests/SheetMusicTests/BracketItemTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/SheetMusicTests/BracketItemTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite struct BracketItemTests {
    @Test func defaultColumnIsZero() {
        let item = BracketItem(type: .brace, span: 2)
        #expect(item.column == 0)
        #expect(item.visible == true)
    }

    @Test func spanLessThanOneIsClamped() {
        let item = BracketItem(type: .normal, span: 0)
        #expect(item.span == 1)

        let neg = BracketItem(type: .normal, span: -3)
        #expect(neg.span == 1)
    }

    @Test func negativeColumnIsClamped() {
        let item = BracketItem(type: .square, span: 1, column: -2)
        #expect(item.column == 0)
    }

    @Test func bracketTypeRawValuesMatchMSCX() {
        // MuseScore's `BracketType` enum raw values used in MSCX
        // serialization (engraving/dom/bracket.h).
        #expect(BracketType.normal.rawValue == 0)
        #expect(BracketType.brace.rawValue == 1)
        #expect(BracketType.square.rawValue == 2)
        #expect(BracketType.line.rawValue == 3)
        #expect(BracketType.noBracket.rawValue == -1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter BracketItemTests`
Expected: FAIL with `cannot find 'BracketItem'` / `cannot find 'BracketType'`.

- [ ] **Step 3: Implement `BracketType` and `BracketItem`**

Create `Sources/SheetMusicCore/Score/BracketItem.swift`:

```swift
import Foundation

/// Bracket / brace style. Mirrors MuseScore's
/// `engraving/dom/bracket.h` `BracketType` enum, including the same
/// raw integer values used in MSCX serialization.
public enum BracketType: Int, Sendable, Equatable, Codable {
    case normal     = 0    // thick angle bracket — section grouping
    case brace      = 1    // curly brace — multi-staff parts
    case square     = 2    // thin angle bracket — same-instrument grouping
    case line       = 3    // plain vertical line, no serifs
    case noBracket  = -1
}

/// One bracket / brace anchored on a `Staff`. The bracket spans
/// `span` staves downward starting from this staff (counting this
/// staff as 1). `column` controls horizontal nesting: 0 is the
/// outermost (closest to the staff), 1 sits one column further left,
/// etc. Multiple bracket items may share a staff.
///
/// C++: `mu::engraving::BracketItem`.
public struct BracketItem: Sendable, Equatable, Codable {
    public var type: BracketType
    public var span: Int
    public var column: Int
    public var visible: Bool

    public init(
        type: BracketType,
        span: Int,
        column: Int = 0,
        visible: Bool = true
    ) {
        self.type = type
        self.span = max(span, 1)
        self.column = max(column, 0)
        self.visible = visible
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter BracketItemTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/BracketItem.swift \
        Tests/SheetMusicTests/BracketItemTests.swift
git commit -m "feat(core): BracketType + BracketItem"
```

---

## Task 2: Extend `Staff` with `brackets`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Staff.swift`
- Test: `Tests/SheetMusicTests/BracketItemTests.swift` (extend)

- [ ] **Step 1: Add a failing test**

Append to `Tests/SheetMusicTests/BracketItemTests.swift`:

```swift
    @Test func staffBracketsDefaultsToEmpty() {
        let s = Staff()
        #expect(s.brackets.isEmpty)
    }

    @Test func staffInitAcceptsBrackets() {
        let s = Staff(brackets: [
            BracketItem(type: .brace, span: 2),
        ])
        #expect(s.brackets.count == 1)
        #expect(s.brackets[0].type == .brace)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter BracketItemTests/staffBracketsDefaultsToEmpty`
Expected: FAIL — compile error: no `brackets` property / parameter on `Staff`.

- [ ] **Step 3: Add `brackets` to `Staff`**

Modify `Sources/SheetMusicCore/Score/Staff.swift`:

```swift
import Foundation

/// A single staff inside a `Part`. ... (existing docstring unchanged)
public struct Staff: Sendable, Equatable {
    /// MuseScore `<StaffType><name>` (e.g. "stdNormal").
    public var staffType: String
    /// MuseScore `<StaffType group="…">` (e.g. "pitched", "percussion").
    public var group: String
    /// MuseScore `<defaultClef>` (e.g. "G", "F", "PERC"). Layout
    /// engines synthesize the opening clef from this when the first
    /// content measure lacks an explicit `<Clef>`.
    public var defaultClefType: String?
    /// MuseScore `<bracket>` children of `<Staff>`, in document order.
    /// Each item anchors one bracket / brace whose span extends
    /// downward from this staff. Empty by default; callers that need
    /// auto-derivation from instrument family must populate this list
    /// themselves before handing the `Score` to the layout engine.
    public var brackets: [BracketItem]
    public var measures: [Measure]

    public init(
        staffType: String = "stdNormal",
        group: String = "pitched",
        defaultClefType: String? = nil,
        brackets: [BracketItem] = [],
        measures: [Measure] = []
    ) {
        self.staffType = staffType
        self.group = group
        self.defaultClefType = defaultClefType
        self.brackets = brackets
        self.measures = measures
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter BracketItemTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Run the whole test suite — defaulted parameter must keep all callers compiling**

Run: `swift build && swift test 2>&1 | tail -20`
Expected: every existing test still PASSes (no behavior change yet — `Staff.brackets` is always empty).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicCore/Score/Staff.swift \
        Tests/SheetMusicTests/BracketItemTests.swift
git commit -m "feat(core): add Staff.brackets (defaulted)"
```

---

## Task 3: MSCX decoder for `<bracket>` elements

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Staff.swift`
- Test: `Tests/SheetMusicTests/BracketDecodingTests.swift`

The current `Staff.declared(_:)` reads `<StaffType>` and `<defaultClef>`. We add a pass that walks every direct `<bracket>` child of `<Staff>` in document order and appends a `BracketItem`. Unknown `type` values, malformed `span`, and other unexpected inputs are silently dropped — consistent with the parser's permissive policy elsewhere.

- [ ] **Step 1: Write the failing decoder tests**

Create `Tests/SheetMusicTests/BracketDecodingTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite struct BracketDecodingTests {
    @Test func decodeBraceWithSpanAndColumn() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="1" span="2" col="0" visible="1"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.brackets.count == 1)
        let b = staff.brackets[0]
        #expect(b.type == .brace)
        #expect(b.span == 2)
        #expect(b.column == 0)
        #expect(b.visible == true)
    }

    @Test func decodeMultipleBracketsOnOneStaff() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="0" span="2" col="0"/>
          <bracket type="2" span="2" col="1"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.brackets.count == 2)
        #expect(staff.brackets[0].type == .normal)
        #expect(staff.brackets[0].column == 0)
        #expect(staff.brackets[1].type == .square)
        #expect(staff.brackets[1].column == 1)
    }

    @Test func decodeOmitsCol() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="2" span="2"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.brackets.count == 1)
        #expect(staff.brackets[0].column == 0)
    }

    @Test func decodeOmitsVisible() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="1" span="2"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.brackets[0].visible == true)
    }

    @Test func decodeVisibleZeroParsesAsFalse() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="1" span="2" visible="0"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.brackets[0].visible == false)
    }

    @Test func decodeUnknownTypeIgnored() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="99" span="1"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.brackets.isEmpty)
    }

    @Test func decodeNegativeSpanClampedToOne() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="0" span="-3"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.brackets.count == 1)
        #expect(staff.brackets[0].span == 1)
    }

    @Test func decodeMissingTypeIgnored() throws {
        // Permissive policy: a <bracket> with no type attribute is dropped.
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket span="2"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.brackets.isEmpty)
    }

    @Test func decodeMissingSpanIgnored() throws {
        // No span → can't produce a meaningful bracket. Drop.
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="1"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.brackets.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter BracketDecodingTests`
Expected: 9 tests FAIL — the decoder doesn't read `<bracket>` yet, so `staff.brackets` is empty for the positive cases and `decodeUnknownTypeIgnored` / `decodeMissingTypeIgnored` / `decodeMissingSpanIgnored` happen to pass trivially.

- [ ] **Step 3: Implement the decoder**

Modify `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Staff.swift`. Replace the existing `Staff.declared(_:)` body so it also walks `<bracket>` children:

```swift
extension Staff {
    /// Decodes the `<StaffType>` / `<defaultClef>` / `<bracket>`
    /// portion of an inside-`<Part><Staff>` element. Measures are
    /// added separately during pairing — see
    /// `assembleParts(decoded:topLevel:)`.
    static func declared(_ node: XMLTreeNode) -> (mscxID: String?, staff: Staff) {
        let staffTypeNode = node.first("StaffType")
        let staffType = staffTypeNode?.first("name")?.text ?? "stdNormal"
        let group = staffTypeNode?.attributes["group"] ?? "pitched"
        let defaultClef = node.first("defaultClef")?.text
        let mscxID = node.attributes["id"]

        // Per spec: walk every <bracket> child in document order so
        // column ordering is preserved. Unknown / malformed values
        // are silently dropped (parser's permissive policy).
        var brackets: [BracketItem] = []
        for el in node.all("bracket") {
            guard let typeStr = el.attributes["type"],
                  let typeRaw = Int(typeStr),
                  let type = BracketType(rawValue: typeRaw)
            else { continue }
            guard let spanStr = el.attributes["span"],
                  let span = Int(spanStr)
            else { continue }
            let column = el.attributes["col"].flatMap(Int.init) ?? 0
            let visible = (el.attributes["visible"] ?? "1") != "0"
            brackets.append(BracketItem(
                type: type,
                span: span,
                column: column,
                visible: visible
            ))
        }

        return (mscxID, Staff(
            staffType: staffType,
            group: group,
            defaultClefType: defaultClef,
            brackets: brackets,
            measures: []
        ))
    }
}
```

- [ ] **Step 4: Run the decoder tests to verify they pass**

Run: `swift test --filter BracketDecodingTests`
Expected: 9 tests PASS.

- [ ] **Step 5: Run the whole suite — fixture-based tests must still parse cleanly**

Run: `swift test 2>&1 | tail -10`
Expected: every existing test PASSes (no MSCX fixture currently has `<bracket>` elements, so behavior is unchanged for them).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Staff.swift \
        Tests/SheetMusicTests/BracketDecodingTests.swift
git commit -m "feat(mscx): decode <bracket> elements into Staff.brackets"
```

---

## Task 4: `LayoutBracket` type + `LayoutSystem.brackets` field

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutSystem.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine.swift` (the `shift` helper)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Ties.swift`

This task adds the field and threads it through every existing `LayoutSystem.init` call site with a default `[]`. No behavior change yet — that comes in Task 6 (geometry pass) and Task 7 (renderer).

- [ ] **Step 1: Add `LayoutBracket` and the new `brackets` field on `LayoutSystem`**

Modify `Sources/SheetMusicLayout/Layout/LayoutSystem.swift`. After the existing `LayoutPartLabel` declaration at the bottom of the file, append:

```swift
@available(macOS 15.0, iOS 16.0, *)
public struct LayoutBracket: Sendable, Equatable {
    public let type: BracketType
    /// Top edge of the topmost spanned staff (system coords).
    public let topY: CGFloat
    /// Bottom edge of the bottommost spanned staff (system coords).
    public let bottomY: CGFloat
    /// Horizontal nesting column. 0 sits closest to the staff; higher
    /// values stack further left.
    public let column: Int

    public init(
        type: BracketType,
        topY: CGFloat,
        bottomY: CGFloat,
        column: Int
    ) {
        self.type = type
        self.topY = topY
        self.bottomY = bottomY
        self.column = column
    }
}
```

Inside the `LayoutSystem` struct itself, add the field next to `partLabels`:

```swift
    /// Brackets / braces drawn at the left edge of this system, one
    /// per `BracketItem` on each staff. Empty when no `Staff.brackets`
    /// were populated upstream.
    public let brackets: [LayoutBracket]
```

Update the initializer signature — add `brackets: [LayoutBracket] = []` immediately after `partLabels`:

```swift
    public init(
        origin: CGPoint,
        size: CGSize,
        measures: [LayoutMeasure],
        staffOrigins: [CGPoint],
        staffAddresses: [StaffAddress] = [],
        partLabels: [LayoutPartLabel],
        brackets: [LayoutBracket] = [],
        spanners: [LayoutElement],
        sp: CGFloat
    ) {
        self.origin = origin
        self.size = size
        self.measures = measures
        self.staffOrigins = staffOrigins
        self.staffAddresses = staffAddresses
        self.partLabels = partLabels
        self.brackets = brackets
        self.spanners = spanners
        self.sp = sp
        let columns = Self.buildEventColumns(measures: measures, sp: sp)
        eventColumns = columns
        maxBBoxHalfWidth = columns
            .map { $0.bbox.width / 2 }
            .max() ?? 0
    }
```

- [ ] **Step 2: Thread `brackets` through the system-rebuild call sites**

Modify `Sources/SheetMusicLayout/Layout/LayoutEngine.swift` `shift(_:byY:)` (around line 130). The existing helper rebuilds with `partLabels: system.partLabels, spanners: ...`. Insert `brackets:`:

```swift
    static func shift(
        _ system: LayoutSystem, byY dy: CGFloat
    ) -> LayoutSystem {
        LayoutSystem(
            origin: CGPoint(
                x: system.origin.x, y: system.origin.y + dy
            ),
            size: system.size,
            measures: system.measures,
            staffOrigins: system.staffOrigins,
            partLabels: system.partLabels,
            brackets: system.brackets,
            spanners: system.spanners,
            sp: system.sp
        )
    }
```

Modify `Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift` (around line 175). Replace the rebuild block:

```swift
        return systems.enumerated().map { idx, system in
            LayoutSystem(
                origin: system.origin,
                size: system.size,
                measures: system.measures,
                staffOrigins: system.staffOrigins,
                partLabels: system.partLabels,
                brackets: system.brackets,
                spanners: system.spanners + extraPerSystem[idx],
                sp: system.sp
            )
        }
```

Modify `Sources/SheetMusicLayout/Layout/LayoutEngine+Ties.swift` (around line 226). Same shape:

```swift
        return systems.enumerated().map { idx, system in
            LayoutSystem(
                origin: system.origin,
                size: system.size,
                measures: system.measures,
                staffOrigins: system.staffOrigins,
                partLabels: system.partLabels,
                brackets: system.brackets,
                spanners: system.spanners + extraPerSystem[idx],
                sp: system.sp
            )
        }
```

(The `LayoutSystem` constructed in `LayoutEngine+SystemBuild.swift::buildSystem` and in `LayoutEngine+Contexts.swift::stickyHeaderSystem` already work with the default `[]`. Task 6 fills in the real value at the SystemBuild site; the sticky header keeps `brackets: []` since brackets aren't shown in the continuous-view sticky pane.)

- [ ] **Step 3: Build the package**

Run: `swift build 2>&1 | tail -20`
Expected: PASS — every existing call site either passes the new value through or relies on the default `[]`.

- [ ] **Step 4: Run the whole test suite — no behavior change expected**

Run: `swift test 2>&1 | tail -20`
Expected: every existing test PASSes. `system.brackets` is `[]` everywhere.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutSystem.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Ties.swift
git commit -m "feat(layout): LayoutBracket + LayoutSystem.brackets field"
```

---

## Task 5: Per-Part label collapse in `buildSystem`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift`
- Modify: `Tests/SheetMusicTests/LayoutPartLabelClefTests.swift`

The current loop at `LayoutEngine+SystemBuild.swift:400` produces one `LayoutPartLabel` per **staff** with Y at the staff's vertical center. We replace it with one label per **Part**, anchored at the vertical midpoint of the part's staff range so multi-staff parts (Piano = staves 2..3 in the fixture) get a single centered label.

`LayoutMeasureContext.partLabels` (sticky header) stays per-staff — see comment in spec.

Note: `LayoutPartLabel.origin.y` keeps its current meaning (vertical center for the label's text baseline anchor).

- [ ] **Step 1: Update the failing test**

Replace the entire body of `Tests/SheetMusicTests/LayoutPartLabelClefTests.swift` (this test predates the rename to per-Part):

```swift
import CoreGraphics
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

@Suite struct LayoutPartLabelClefTests {
    @available(macOS 15.0, iOS 16.0, *)
    @Test func measureContextsKeepPerStaffLabels() throws {
        // The sticky-header context keeps one label per staff so each
        // staff line in the continuous-view pane gets its own name.
        let url = try #require(
            Bundle.module.url(
                forResource: "multiPartMixedStaves",
                withExtension: "mscx"
            )
        )
        let score = try MSCXParser.parse(contentsOf: url)

        let contexts = LayoutEngine.measureContexts(for: score)
        let m0 = try #require(contexts.first)

        // Display order: [Vln1, Vln2, Piano-RH, Piano-LH, Vc].
        #expect(m0.partLabels[0] == "Violin 1")
        #expect(m0.partLabels[1] == "Violin 2")
        #expect(m0.partLabels[2] == "Piano")
        #expect(m0.partLabels[3] == "Piano")
        #expect(m0.partLabels[4] == "Violoncello")

        // Default clef chain expected: G, G, G, F, F.
        #expect(m0.clefRawTypes == ["G", "G", "G", "F", "F"])
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func systemPartLabelsCollapseToOnePerPart() throws {
        // The system's left-edge labels collapse to one entry per
        // Part. Piano (multi-staff) gets a single label centered
        // between its two staves.
        let url = try #require(
            Bundle.module.url(
                forResource: "multiPartMixedStaves",
                withExtension: "mscx"
            )
        )
        let score = try MSCXParser.parse(contentsOf: url)
        let doc = LayoutEngine.layout(
            score: score,
            options: .init()
        )
        let system = try #require(doc.systems.first)

        // 4 parts: Vln1, Vln2, Piano (1 entry, 2 staves), Vc.
        #expect(system.partLabels.count == 4)
        #expect(system.partLabels[0].text == "Violin 1")
        #expect(system.partLabels[1].text == "Violin 2")
        #expect(system.partLabels[2].text == "Piano")
        #expect(system.partLabels[3].text == "Violoncello")

        // Piano label sits at the midpoint between staff 2's top and
        // staff 3's bottom (within ±0.5 sp).
        let metrics = doc.metrics
        let pianoTopY = system.staffOrigins[2].y
        let pianoBottomY = system.staffOrigins[3].y + metrics.staffHeight
        let expectedY = (pianoTopY + pianoBottomY) / 2
        let actualY = system.partLabels[2].origin.y
        #expect(abs(actualY - expectedY) <= metrics.sp * 0.5)
    }
}
```

(`LayoutEngine.layout` and `ScoreViewOptions` / `.init()` exist; verify by inspecting `LayoutEngine.swift` if unsure.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LayoutPartLabelClefTests/systemPartLabelsCollapseToOnePerPart`
Expected: FAIL — `partLabels.count` is 5 (one per staff), not 4.

- [ ] **Step 3: Implement the per-Part collapse**

Modify `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift`. Find the block starting at line 400 (`let labels: [LayoutPartLabel] = allStaves.enumerated().map ...`) and replace it with a per-Part loop that resolves each part's flat-staff range and anchors the label at the midpoint:

```swift
        // Per-Part labels. Multi-staff parts (Piano grand staff)
        // collapse to a single label centered between the topmost
        // and bottommost spanned staves, matching engraving
        // convention. Single-staff parts trivially center on their
        // one staff.
        let labels: [LayoutPartLabel] = context.score.parts.enumerated().compactMap { partIdx, part in
            let text: String
            if isFirstSystem {
                text = part.instrument.longName
                    ?? part.trackName
                    ?? ""
            } else {
                text = part.instrument.shortName
                    ?? part.instrument.longName.map { String($0.prefix(3)) }
                    ?? part.trackName.map { String($0.prefix(3)) }
                    ?? ""
            }
            // Locate the part's flat-staff range. A part with no
            // entries in `allStaves` (shouldn't normally happen — a
            // Part declares staves that always end up flattened)
            // is skipped silently.
            guard let firstFlat = allStaves.firstIndex(where: {
                $0.address.partIndex == partIdx
            }), let lastFlat = allStaves.lastIndex(where: {
                $0.address.partIndex == partIdx
            }) else { return nil }
            let topY = staffOrigins[firstFlat].y
            let bottomY = staffOrigins[lastFlat].y + metrics.staffHeight
            let centerY = (topY + bottomY) / 2
            return LayoutPartLabel(
                text: text,
                origin: CGPoint(x: 4, y: centerY)
            )
        }
```

The `topShift` / `adjustedLabels` block lower in the function already maps each label's `origin.y += topShift`, so the per-Part `centerY` flows through unchanged.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter LayoutPartLabelClefTests`
Expected: 2 tests PASS.

- [ ] **Step 5: Run the whole suite — watch for regressions in label-positioning tests**

Run: `swift test 2>&1 | tail -30`
Expected: every test PASSes. Any test that asserts on `system.partLabels.count == score.allStaves.count` would break here — the spec explicitly calls this out as a behavior change. If a test does fail on that assertion, update it to use `score.parts.count` and adjust the expected text.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift \
        Tests/SheetMusicTests/LayoutPartLabelClefTests.swift
git commit -m "feat(layout): collapse partLabels to one entry per Part"
```

---

## Task 6: Bracket geometry pass in `buildSystem`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift`
- Test: `Tests/SheetMusicTests/LayoutBracketTests.swift`

This task threads `Staff.brackets` → `LayoutSystem.brackets`. It also widens the left gutter so columned brackets have room to stack. Approach:

- Compute `bracketColumnCount = (max column across all `Staff.brackets`) + 1` (or 0 if no brackets).
- Pass that count into `labelWidth` so the gutter reserves `bracketColumnCount * sp * 1.0 + sp * 0.5` extra space on top of label width.
- Walk `score.parts × staves × brackets` after `staffOrigins` is finalized; for each visible `BracketItem` whose `type != .noBracket`, build a `LayoutBracket` with `topY = staffOrigins[origin].y`, `bottomY = staffOrigins[clampedEnd].y + staffHeight`. Clamp `span` so `originFlat + span - 1 <= staffOrigins.count - 1`.
- Apply `topShift` to the bracket Y values when the system shifts.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/LayoutBracketTests.swift`:

```swift
import CoreGraphics
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite struct LayoutBracketTests {
    /// Hand-built score with brackets — avoids round-tripping through
    /// MSCX, so geometry logic can be verified independently.
    private static func makeScore() -> Score {
        let measure = Measure(voices: [
            Voice(elements: [
                .rest(Rest(durationType: "measure"))
            ]),
        ])
        // Vln1 (single staff with NORMAL bracket span 2 column 0
        // and SQUARE bracket span 2 column 1).
        let vln1 = Part(
            id: "1",
            trackName: "Violin 1",
            instrument: Instrument(longName: "Violin 1"),
            staves: [Staff(
                defaultClefType: "G",
                brackets: [
                    BracketItem(type: .normal, span: 2, column: 0),
                    BracketItem(type: .square, span: 2, column: 1),
                ],
                measures: [measure]
            )]
        )
        let vln2 = Part(
            id: "2",
            trackName: "Violin 2",
            instrument: Instrument(longName: "Violin 2"),
            staves: [Staff(
                defaultClefType: "G",
                measures: [measure]
            )]
        )
        // Piano: 2 staves with BRACE on staff 0, span 2.
        let piano = Part(
            id: "3",
            trackName: "Piano",
            instrument: Instrument(longName: "Piano"),
            staves: [
                Staff(
                    defaultClefType: "G",
                    brackets: [BracketItem(type: .brace, span: 2)],
                    measures: [measure]
                ),
                Staff(
                    defaultClefType: "F",
                    measures: [measure]
                ),
            ]
        )
        return Score(division: 480, parts: [vln1, vln2, piano])
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func layoutBracketYFollowsStaffOrigins() {
        let doc = LayoutEngine.layout(
            score: Self.makeScore(),
            options: .init()
        )
        let system = doc.systems[0]

        // Three distinct items: NORMAL (vln1+vln2), SQUARE
        // (vln1+vln2 nested), BRACE (piano).
        #expect(system.brackets.count == 3)

        // Find the BRACE.
        let brace = try! #require(
            system.brackets.first(where: { $0.type == .brace })
        )
        // Piano staves are flat indices 2 and 3.
        #expect(abs(brace.topY - system.staffOrigins[2].y) < 0.001)
        let metrics = doc.metrics
        let pianoBottom = system.staffOrigins[3].y + metrics.staffHeight
        #expect(abs(brace.bottomY - pianoBottom) < 0.001)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func layoutBracketColumnAffectsXPosition() {
        // Column-1 brackets are present; the gutter widens to
        // accommodate `max column + 1` columns.
        let doc = LayoutEngine.layout(
            score: Self.makeScore(),
            options: .init()
        )
        let system = doc.systems[0]
        let columns = system.brackets.map(\.column)
        #expect(columns.contains(0))
        #expect(columns.contains(1))

        // Gutter width = staff origin X. Compare against a score
        // with no brackets at all.
        let bareScore = Score(
            division: 480,
            parts: [
                Part(
                    id: "1",
                    trackName: "Violin 1",
                    instrument: Instrument(longName: "Violin 1"),
                    staves: [Staff(
                        defaultClefType: "G",
                        measures: Self.makeScore().parts[0].staves[0].measures
                    )]
                ),
            ]
        )
        let bareDoc = LayoutEngine.layout(
            score: bareScore,
            options: .init()
        )
        let bareGutter = bareDoc.systems[0].staffOrigins[0].x
        let bracketGutter = system.staffOrigins[0].x
        // With a column-1 bracket present, the gutter must be at
        // least one extra `sp` wider.
        #expect(bracketGutter > bareGutter + doc.metrics.sp * 0.9)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func bracketSpanClampedAtScoreEnd() {
        // A bracket whose span overshoots the last staff is silently
        // clamped — the layout doesn't crash and the bracket bottomY
        // pins to the last staff.
        let measure = Measure(voices: [
            Voice(elements: [.rest(Rest(durationType: "measure"))]),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                trackName: "P",
                instrument: Instrument(longName: "P"),
                staves: [Staff(
                    defaultClefType: "G",
                    brackets: [BracketItem(type: .normal, span: 99)],
                    measures: [measure]
                )]
            )]
        )
        let doc = LayoutEngine.layout(score: score, options: .init())
        let system = doc.systems[0]
        #expect(system.brackets.count == 1)
        let metrics = doc.metrics
        let lastBottom = system.staffOrigins
            .last!.y + metrics.staffHeight
        #expect(abs(system.brackets[0].bottomY - lastBottom) < 0.001)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func noBracketTypeNotEmitted() {
        let measure = Measure(voices: [
            Voice(elements: [.rest(Rest(durationType: "measure"))]),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                trackName: "P",
                instrument: Instrument(longName: "P"),
                staves: [Staff(
                    defaultClefType: "G",
                    brackets: [BracketItem(type: .noBracket, span: 1)],
                    measures: [measure]
                )]
            )]
        )
        let doc = LayoutEngine.layout(score: score, options: .init())
        #expect(doc.systems[0].brackets.isEmpty)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func invisibleBracketNotEmitted() {
        let measure = Measure(voices: [
            Voice(elements: [.rest(Rest(durationType: "measure"))]),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                trackName: "P",
                instrument: Instrument(longName: "P"),
                staves: [Staff(
                    defaultClefType: "G",
                    brackets: [BracketItem(
                        type: .normal, span: 1, visible: false
                    )],
                    measures: [measure]
                )]
            )]
        )
        let doc = LayoutEngine.layout(score: score, options: .init())
        #expect(doc.systems[0].brackets.isEmpty)
    }
}
```

(If the test file fails to compile because of unrelated `Voice` / `Rest` / `Measure` initializer mismatches, snapshot the existing `MultiPartStaffMappingTests.swift` or another in-memory-Score test for the right argument shapes and update the helper accordingly. The point of the test is the bracket assertions, not fixture construction.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LayoutBracketTests`
Expected: 5 tests FAIL — `system.brackets` is empty everywhere because the geometry pass doesn't exist yet.

- [ ] **Step 3: Widen the gutter — accept `bracketColumnCount` in `labelWidth`**

Modify `Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift`. Update `labelWidth` to take a bracket-column count and add `column * sp * 1 + sp * 0.5` to the result:

```swift
    static func labelWidth(
        score: Score,
        metrics: StaffMetrics,
        useLong: Bool,
        bracketColumnCount: Int = 0
    ) -> CGFloat {
        let labels: [String] = score.parts.map { part in
            if useLong {
                part.instrument.longName
                    ?? part.trackName
                    ?? ""
            } else {
                part.instrument.shortName
                    ?? part.instrument.longName.map { String($0.prefix(3)) }
                    ?? part.trackName.map { String($0.prefix(3)) }
                    ?? ""
            }
        }
        let fontSize = metrics.sp * 2.5
        var widest: CGFloat = 0
        for text in labels where !text.isEmpty {
            widest = max(
                widest,
                LayoutEngine.lyricsTextWidth(text, sp: metrics.sp)
                    * (fontSize / (metrics.sp * 2.2))
            )
        }
        let pad = metrics.sp * 1
        let floor = useLong ? metrics.sp * 4 : metrics.sp * 2
        // Reserve room for bracket columns on the staff's left side.
        // One column ≈ sp * 1 of horizontal stride; the base inset
        // (sp * 0.5) is the bracket-spine-to-staff distance.
        let bracketGutter: CGFloat = bracketColumnCount > 0
            ? CGFloat(bracketColumnCount) * metrics.sp + metrics.sp * 0.5
            : 0
        return max(floor, widest + pad) + bracketGutter
    }
```

- [ ] **Step 4: Compute `bracketColumnCount` at the call site and emit `LayoutBracket`s in `buildSystem`**

Modify `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift`.

(a) Replace the `partLabelWidth` setup near the top of `buildSystem` (around line 21):

```swift
        // Bracket-column count: max column index across every staff's
        // BracketItems, +1. Zero when no part declares a bracket.
        let bracketColumnCount: Int = {
            var maxCol: Int = -1
            for part in context.score.parts {
                for staff in part.staves {
                    for bi in staff.brackets where bi.visible
                        && bi.type != .noBracket
                    {
                        if bi.column > maxCol { maxCol = bi.column }
                    }
                }
            }
            return maxCol + 1
        }()
        let partLabelWidth: CGFloat = labelWidth(
            score: context.score,
            metrics: metrics,
            useLong: isFirstSystem,
            bracketColumnCount: bracketColumnCount
        )
```

(b) After `staffOrigins` is finalized (the loop ending at line ~394 — search for `currentY += metrics.staffHeight + staffBottomPads[idx] + minGap`), and BEFORE the per-Part labels loop, insert the bracket emission pass:

```swift
        // Build LayoutBrackets — one per visible BracketItem on each
        // staff. `span` overshooting the last staff is silently
        // clamped, mirroring MuseScore's `BracketItem::staffIdx2`.
        var brackets: [LayoutBracket] = []
        for (partIdx, part) in context.score.parts.enumerated() {
            guard let partFirstFlat = allStaves.firstIndex(where: {
                $0.address.partIndex == partIdx
            }) else { continue }
            for (staffIdxInPart, staff) in part.staves.enumerated() {
                let originFlat = partFirstFlat + staffIdxInPart
                guard originFlat < staffOrigins.count else { continue }
                for bi in staff.brackets where bi.visible
                    && bi.type != .noBracket
                {
                    let endFlat = min(
                        originFlat + bi.span - 1,
                        staffOrigins.count - 1
                    )
                    let topY = staffOrigins[originFlat].y
                    let bottomY = staffOrigins[endFlat].y
                        + metrics.staffHeight
                    brackets.append(LayoutBracket(
                        type: bi.type,
                        topY: topY,
                        bottomY: bottomY,
                        column: bi.column
                    ))
                }
            }
        }
```

(c) Update the `topShift` adjustment block (currently around line 528-541) so brackets shift along with `staffOrigins` and `partLabels`:

```swift
        let adjustedBrackets = topShift > 0
            ? brackets.map {
                LayoutBracket(
                    type: $0.type,
                    topY: $0.topY + topShift,
                    bottomY: $0.bottomY + topShift,
                    column: $0.column
                )
            }
            : brackets
```

(d) Pass `brackets:` through to `LayoutSystem.init` in the `return LayoutSystem(...)` block at the end of `buildSystem`:

```swift
        return LayoutSystem(
            origin: CGPoint(x: 0, y: systemOriginY),
            size: CGSize(width: xCursor, height: totalHeight + topShift),
            measures: adjustedMeasures,
            staffOrigins: adjustedStaffOrigins,
            staffAddresses: allStaves.map(\.address),
            partLabels: adjustedLabels,
            brackets: adjustedBrackets,
            spanners: [],
            sp: metrics.sp
        )
```

- [ ] **Step 5: Run the bracket-layout tests to verify they pass**

Run: `swift test --filter LayoutBracketTests`
Expected: 5 tests PASS.

- [ ] **Step 6: Run the whole suite**

Run: `swift test 2>&1 | tail -20`
Expected: every test PASSes. The gutter widening might shift X coordinates in pre-existing layout-X tests; if any fail, inspect the failure and either widen the assertion's tolerance to account for the new gutter (when the test isn't asserting bracket-related behavior) or update the expected value. Do NOT relax assertions blindly — read each failing test before adjusting it.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift \
        Tests/SheetMusicTests/LayoutBracketTests.swift
git commit -m "feat(layout): emit LayoutBracket per Staff.BracketItem"
```

---

## Task 7: Update the `multiPartMixedStaves` MSCX fixture

**Files:**
- Modify: `Tests/SheetMusicTests/Resources/multiPartMixedStaves.mscx`
- Test: extend `LayoutBracketTests`

This task wires the decoder + layout to a real MSCX file end-to-end. Three brackets — outer NORMAL spanning Vln1+Vln2, nested SQUARE on the same pair, BRACE on the Piano grand staff.

- [ ] **Step 1: Add a failing end-to-end test**

Append to `Tests/SheetMusicTests/LayoutBracketTests.swift`:

```swift
    @available(macOS 15.0, iOS 16.0, *)
    @Test func multiPartMixedStavesFixtureBrackets() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "multiPartMixedStaves",
                withExtension: "mscx"
            )
        )
        let score = try MSCXParser.parse(contentsOf: url)

        // Vln1 declares NORMAL (col 0) + SQUARE (col 1); Piano (parts[2])
        // declares BRACE on its top staff.
        #expect(score.parts[0].staves[0].brackets.count == 2)
        #expect(score.parts[0].staves[0].brackets.contains {
            $0.type == .normal && $0.span == 2 && $0.column == 0
        })
        #expect(score.parts[0].staves[0].brackets.contains {
            $0.type == .square && $0.span == 2 && $0.column == 1
        })
        #expect(score.parts[2].staves[0].brackets.count == 1)
        #expect(score.parts[2].staves[0].brackets[0].type == .brace)

        // End-to-end: layout produces three LayoutBrackets.
        let doc = LayoutEngine.layout(score: score, options: .init())
        let kinds = doc.systems[0].brackets
            .map(\.type).sorted { $0.rawValue < $1.rawValue }
        #expect(kinds == [.normal, .brace, .square])
    }
```

(Add `@testable import SheetMusicMSCX` at the top of the file if not already imported.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LayoutBracketTests/multiPartMixedStavesFixtureBrackets`
Expected: FAIL — current fixture has no `<bracket>` elements.

- [ ] **Step 3: Update the fixture**

Replace `Tests/SheetMusicTests/Resources/multiPartMixedStaves.mscx` with this content (only Part 1 and Part 3 staves change — adding `<bracket>` lines):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="4.60">
  <Score>
    <Division>480</Division>
    <Part id="1">
      <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType><defaultClef>G</defaultClef><bracket type="0" span="2" col="0" visible="1"/><bracket type="2" span="2" col="1" visible="1"/></Staff>
      <trackName>Violin 1</trackName>
      <Instrument id="violin"><longName>Violin 1</longName></Instrument>
    </Part>
    <Part id="2">
      <Staff id="2"><StaffType group="pitched"><name>stdNormal</name></StaffType><defaultClef>G</defaultClef></Staff>
      <trackName>Violin 2</trackName>
      <Instrument id="violin"><longName>Violin 2</longName></Instrument>
    </Part>
    <Part id="3">
      <Staff id="3"><StaffType group="pitched"><name>stdNormal</name></StaffType><defaultClef>G</defaultClef><bracket type="1" span="2" col="0" visible="1"/></Staff>
      <Staff id="4"><StaffType group="pitched"><name>stdNormal</name></StaffType><defaultClef>F</defaultClef></Staff>
      <trackName>Piano</trackName>
      <Instrument id="piano"><longName>Piano</longName></Instrument>
    </Part>
    <Part id="4">
      <Staff id="5"><StaffType group="pitched"><name>stdNormal</name></StaffType><defaultClef>F</defaultClef></Staff>
      <trackName>Violoncello</trackName>
      <Instrument id="violoncello"><longName>Violoncello</longName></Instrument>
    </Part>
    <Staff id="1"><Measure><voice><Rest><durationType>measure</durationType><duration>4/4</duration></Rest></voice></Measure></Staff>
    <Staff id="2"><Measure><voice><Rest><durationType>measure</durationType><duration>4/4</duration></Rest></voice></Measure></Staff>
    <Staff id="3"><Measure><voice><Rest><durationType>measure</durationType><duration>4/4</duration></Rest></voice></Measure></Staff>
    <Staff id="4"><Measure><voice><Rest><durationType>measure</durationType><duration>4/4</duration></Rest></voice></Measure></Staff>
    <Staff id="5"><Measure><voice><Rest><durationType>measure</durationType><duration>4/4</duration></Rest></voice></Measure></Staff>
  </Score>
</museScore>
```

- [ ] **Step 4: Run the new fixture test**

Run: `swift test --filter LayoutBracketTests/multiPartMixedStavesFixtureBrackets`
Expected: PASS.

- [ ] **Step 5: Run the full suite — fixture is shared**

Run: `swift test 2>&1 | tail -30`
Expected: every test PASSes. Tests like `MidiExportTests` round-trip mscx → MIDI but don't care about brackets, so they remain green. If any test asserts byte-equality on the fixture, update its expected bytes.

- [ ] **Step 6: Commit**

```bash
git add Tests/SheetMusicTests/Resources/multiPartMixedStaves.mscx \
        Tests/SheetMusicTests/LayoutBracketTests.swift
git commit -m "test(mscx): multiPartMixedStaves fixture gains <bracket> markup"
```

---

## Task 8: Render brackets — replace `drawBracket` with `drawBrackets`

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Staves.swift`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder.swift`
- Modify: `Sources/SheetMusicUI/Rendering/StaffRenderer.swift`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift`
- Test: `Tests/SheetMusicTests/BracketRenderingTests.swift`

Two parallel renderers exist: a CALayer-based path (`ScoreLayerBuilder+Staves.swift`) used by the layer-tree exporter, and a SwiftUI `GraphicsContext` path (`StaffRenderer.swift`) used by `ScoreCanvas`. Both must learn to dispatch on `BracketType`.

Geometric constants (sp = staff space):

| Type   | Spine width | Serif width | Serif length | Notes |
|--------|-------------|-------------|--------------|-------|
| normal | sp * 0.3    | sp * 0.25   | sp * 0.8     | Same as today's `drawBracket`. |
| square | sp * 0.15   | sp * 0.15   | sp * 0.5     | Half-weight serifs, drawn as horizontal strokes. |
| line   | sp * 0.15   | —           | —            | Spine only, no serifs. |
| brace  | SMuFL `U+E000` glyph (Bravura), Y-scaled to fit `[topY, bottomY]`. |

X positioning per column (system-coords; `staffOriginX = system.staffOrigins.first?.x ?? 0`):

```
spineX = staffOriginX - sp * 0.5 - CGFloat(column) * sp * 1.0
```

Brace glyph X: right edge sits at `staffOriginX - sp * 0.3` (column 0 only — the SMuFL brace doesn't tile into nested columns). Compute the brace's natural height via `CTFontGetBoundingRectsForGlyphs` and apply a Y-scale of `targetHeight / naturalHeight`.

- [ ] **Step 1: Write the failing rendering test**

Create `Tests/SheetMusicTests/BracketRenderingTests.swift`:

```swift
#if canImport(QuartzCore)
import CoreGraphics
import Foundation
import QuartzCore
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicUI
import Testing

@Suite struct BracketRenderingTests {
    /// Counts shape (stroke) sublayers and text sublayers in a tree.
    private static func countLayerKinds(
        _ root: CALayer
    ) -> (shapes: Int, texts: Int) {
        var shapes = 0, texts = 0
        func walk(_ layer: CALayer) {
            if layer is CAShapeLayer { shapes += 1 }
            if layer is CATextLayer { texts += 1 }
            for sub in layer.sublayers ?? [] { walk(sub) }
        }
        walk(root)
        return (shapes, texts)
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func sampleSystem(
        type: BracketType
    ) -> LayoutSystem {
        let metrics = StaffMetrics(staffSize: 28)
        return LayoutSystem(
            origin: .zero,
            size: CGSize(width: 200, height: 200),
            measures: [],
            staffOrigins: [
                CGPoint(x: 60, y: 20),
                CGPoint(x: 60, y: 80),
            ],
            partLabels: [],
            brackets: [LayoutBracket(
                type: type,
                topY: 20,
                bottomY: 80 + metrics.staffHeight,
                column: 0
            )],
            spanners: [],
            sp: metrics.sp
        )
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func normalBracketEmitsStrokes() {
        let metrics = StaffMetrics(staffSize: 28)
        let system = Self.sampleSystem(type: .normal)
        let root = CALayer()
        ScoreLayerBuilder.drawBrackets(
            system: system, metrics: metrics,
            height: system.size.height, into: root
        )
        let counts = Self.countLayerKinds(root)
        #expect(counts.shapes >= 1)
        #expect(counts.texts == 0)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func braceBracketEmitsTextLayer() {
        let metrics = StaffMetrics(staffSize: 28)
        let system = Self.sampleSystem(type: .brace)
        let root = CALayer()
        ScoreLayerBuilder.drawBrackets(
            system: system, metrics: metrics,
            height: system.size.height, into: root
        )
        let counts = Self.countLayerKinds(root)
        #expect(counts.texts >= 1)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func lineBracketHasNoSerifs() {
        let metrics = StaffMetrics(staffSize: 28)
        let system = Self.sampleSystem(type: .line)
        let root = CALayer()
        ScoreLayerBuilder.drawBrackets(
            system: system, metrics: metrics,
            height: system.size.height, into: root
        )
        let counts = Self.countLayerKinds(root)
        // Just the spine — exactly 1 stroke layer, no serif strokes.
        #expect(counts.shapes == 1)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func emptyBracketsEmitsNothing() {
        let metrics = StaffMetrics(staffSize: 28)
        let system = LayoutSystem(
            origin: .zero,
            size: CGSize(width: 200, height: 200),
            measures: [],
            staffOrigins: [.init(x: 60, y: 20)],
            partLabels: [],
            brackets: [],
            spanners: [],
            sp: metrics.sp
        )
        let root = CALayer()
        ScoreLayerBuilder.drawBrackets(
            system: system, metrics: metrics,
            height: system.size.height, into: root
        )
        #expect((root.sublayers ?? []).isEmpty)
    }
}
#endif
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BracketRenderingTests`
Expected: FAIL — `drawBrackets` does not exist (only the legacy `drawBracket` does).

- [ ] **Step 3: Replace `drawBracket` with `drawBrackets` in `ScoreLayerBuilder+Staves.swift`**

Modify `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Staves.swift`. Remove the old `drawBracket` (lines 38-73) and add a typed dispatcher plus per-type helpers:

```swift
    static func drawBrackets(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        guard !system.brackets.isEmpty else { return }
        let staffOriginX = system.staffOrigins.first?.x ?? 0
        for b in system.brackets {
            switch b.type {
            case .noBracket:
                continue
            case .brace:
                drawBrace(
                    bracket: b, staffOriginX: staffOriginX,
                    metrics: metrics, height: height, into: parent
                )
            case .normal:
                drawAngleBracket(
                    bracket: b, staffOriginX: staffOriginX,
                    spineWidth: metrics.sp * 0.3,
                    serifWidth: metrics.sp * 0.25,
                    serifLength: metrics.sp * 0.8,
                    metrics: metrics, height: height, into: parent
                )
            case .square:
                drawAngleBracket(
                    bracket: b, staffOriginX: staffOriginX,
                    spineWidth: metrics.sp * 0.15,
                    serifWidth: metrics.sp * 0.15,
                    serifLength: metrics.sp * 0.5,
                    metrics: metrics, height: height, into: parent
                )
            case .line:
                drawLineBracket(
                    bracket: b, staffOriginX: staffOriginX,
                    metrics: metrics, height: height, into: parent
                )
            }
        }
    }

    private static func bracketSpineX(
        column: Int, staffOriginX: CGFloat, sp: CGFloat
    ) -> CGFloat {
        staffOriginX - sp * 0.5 - CGFloat(column) * sp
    }

    private static func drawAngleBracket(
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        spineWidth: CGFloat,
        serifWidth: CGFloat,
        serifLength: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: metrics.sp
        )
        let topPt = CGPoint(x: x, y: b.topY)
        let botPt = CGPoint(x: x, y: b.bottomY)
        let spine = CGMutablePath()
        spine.move(to: topPt)
        spine.addLine(to: botPt)
        parent.addSublayer(strokeLayer(
            path: spine, height: height, lineWidth: spineWidth
        ))
        for point in [topPt, botPt] {
            let serif = CGMutablePath()
            serif.move(to: point)
            serif.addLine(to: CGPoint(
                x: point.x + serifLength, y: point.y
            ))
            parent.addSublayer(strokeLayer(
                path: serif, height: height, lineWidth: serifWidth
            ))
        }
    }

    private static func drawLineBracket(
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: metrics.sp
        )
        let spine = CGMutablePath()
        spine.move(to: CGPoint(x: x, y: b.topY))
        spine.addLine(to: CGPoint(x: x, y: b.bottomY))
        parent.addSublayer(strokeLayer(
            path: spine, height: height, lineWidth: metrics.sp * 0.15
        ))
    }

    /// Brace via Bravura `U+E000`. Y-scaled to fit the requested
    /// span. Glyph's right edge is anchored sp*0.3 to the left of the
    /// staff origin (braces sit closest to the staff; nested columns
    /// don't apply).
    private static func drawBrace(
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        _ = BravuraFont.register
        let fontSize = metrics.sp * 4
        let font = CTFontCreateWithName(
            BravuraFont.familyName as CFString,
            fontSize, nil
        )
        var unichars: [UniChar] = [0xE000]
        var glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(
            font, &unichars, &glyphs, 1
        ) else { return }
        var bbox = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(
            font, .horizontal, &glyphs, &bbox, 1
        )
        let nativeHeight = bbox.height
        guard nativeHeight > 0 else { return }
        let target = b.bottomY - b.topY
        let yScale = target / nativeHeight
        let layer = CATextLayer()
        layer.string = String(UnicodeScalar(0xE000)!)
        layer.font = font
        layer.fontSize = fontSize
        layer.alignmentMode = .left
        layer.foregroundColor = CGColor(gray: 0, alpha: 1)
        // Right edge of the glyph anchors at staffOriginX - sp*0.3.
        let glyphWidth = bbox.width * 1.0  // x not scaled
        let x = staffOriginX - metrics.sp * 0.3 - glyphWidth
        // CATextLayer is in flipped coords for our drawing model
        // (height-y handled in `strokeLayer`); for a glyph layer we
        // place its frame so vertical center sits between topY and
        // bottomY, and we apply yScale via affine transform.
        let frame = CGRect(
            x: x, y: height - b.bottomY,
            width: glyphWidth,
            height: nativeHeight
        )
        layer.frame = frame
        layer.contentsScale = 2
        // Y-scale via affineTransform around the layer's anchor.
        layer.transform = CATransform3DMakeScale(1, yScale, 1)
        parent.addSublayer(layer)
    }
```

(If `BravuraFont` is in a different module's namespace and not visible from this file, add `import SheetMusicLayout` or wherever `BravuraFont` is declared. Confirm with `grep -n "public enum BravuraFont" Sources` — current location is `Sources/SheetMusicLayout/Fonts/BravuraFont.swift`.)

- [ ] **Step 4: Update the call site in `ScoreLayerBuilder.swift`**

Modify `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder.swift`. Replace the `drawBracket(...)` call (around line 85) with `drawBrackets(...)`:

```swift
        drawBrackets(
            system: system, metrics: metrics,
            height: height, into: root
        )
```

- [ ] **Step 5: Update the SwiftUI renderer**

Modify `Sources/SheetMusicUI/Rendering/StaffRenderer.swift`. Replace the existing `drawBracket(context:top:bottom:metrics:)` with a typed `drawBrackets(context:system:metrics:)` that mirrors the dispatch logic. Use `context.draw(_, in: CGRect)` for the brace glyph (build a `Text("\u{E000}").font(.custom("Bravura", size: ...))` resolved to an image), and `context.stroke(_:with:lineWidth:)` for the others:

```swift
    static func drawBrackets(
        context: inout GraphicsContext,
        system: LayoutSystem,
        metrics: StaffMetrics
    ) {
        guard !system.brackets.isEmpty,
              let firstStaffOrigin = system.staffOrigins.first
        else { return }
        let staffOriginX = system.origin.x + firstStaffOrigin.x
        for b in system.brackets {
            switch b.type {
            case .noBracket: continue
            case .brace:
                drawBrace(
                    context: &context,
                    bracket: b,
                    staffOriginX: staffOriginX,
                    systemOriginY: system.origin.y,
                    metrics: metrics
                )
            case .normal:
                drawAngleBracket(
                    context: &context,
                    bracket: b,
                    staffOriginX: staffOriginX,
                    systemOriginY: system.origin.y,
                    spineWidth: metrics.sp * 0.3,
                    serifWidth: metrics.sp * 0.25,
                    serifLength: metrics.sp * 0.8,
                    metrics: metrics
                )
            case .square:
                drawAngleBracket(
                    context: &context,
                    bracket: b,
                    staffOriginX: staffOriginX,
                    systemOriginY: system.origin.y,
                    spineWidth: metrics.sp * 0.15,
                    serifWidth: metrics.sp * 0.15,
                    serifLength: metrics.sp * 0.5,
                    metrics: metrics
                )
            case .line:
                drawLineBracket(
                    context: &context,
                    bracket: b,
                    staffOriginX: staffOriginX,
                    systemOriginY: system.origin.y,
                    metrics: metrics
                )
            }
        }
    }

    private static func bracketSpineX(
        column: Int, staffOriginX: CGFloat, sp: CGFloat
    ) -> CGFloat {
        staffOriginX - sp * 0.5 - CGFloat(column) * sp
    }

    private static func drawAngleBracket(
        context: inout GraphicsContext,
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        systemOriginY: CGFloat,
        spineWidth: CGFloat,
        serifWidth: CGFloat,
        serifLength: CGFloat,
        metrics: StaffMetrics
    ) {
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: metrics.sp
        )
        let topY = systemOriginY + b.topY
        let botY = systemOriginY + b.bottomY
        var spine = Path()
        spine.move(to: CGPoint(x: x, y: topY))
        spine.addLine(to: CGPoint(x: x, y: botY))
        context.stroke(
            spine, with: .color(.primary), lineWidth: spineWidth
        )
        for y in [topY, botY] {
            var serif = Path()
            serif.move(to: CGPoint(x: x, y: y))
            serif.addLine(to: CGPoint(x: x + serifLength, y: y))
            context.stroke(
                serif, with: .color(.primary), lineWidth: serifWidth
            )
        }
    }

    private static func drawLineBracket(
        context: inout GraphicsContext,
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        systemOriginY: CGFloat,
        metrics: StaffMetrics
    ) {
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: metrics.sp
        )
        var spine = Path()
        spine.move(to: CGPoint(x: x, y: systemOriginY + b.topY))
        spine.addLine(to: CGPoint(x: x, y: systemOriginY + b.bottomY))
        context.stroke(
            spine, with: .color(.primary), lineWidth: metrics.sp * 0.15
        )
    }

    private static func drawBrace(
        context: inout GraphicsContext,
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        systemOriginY: CGFloat,
        metrics: StaffMetrics
    ) {
        _ = BravuraFont.register
        let target = b.bottomY - b.topY
        let nominalSize = metrics.sp * 4
        let braceText = Text(String(UnicodeScalar(0xE000)!))
            .font(.custom(BravuraFont.familyName, fixedSize: nominalSize))
        var resolved = context.resolve(braceText)
        let measured = resolved.measure(in: CGSize(
            width: 100, height: 1000
        ))
        guard measured.height > 0 else { return }
        let yScale = target / measured.height
        let xPos = staffOriginX - metrics.sp * 0.3 - measured.width
        let yPos = systemOriginY + b.topY
        var sub = context
        sub.translateBy(x: xPos, y: yPos)
        sub.scaleBy(x: 1, y: yScale)
        sub.draw(resolved, at: .zero, anchor: .topLeading)
    }
```

(`Text.font(.custom(_:fixedSize:))` exists in iOS 16 / macOS 13 — `BravuraFont.familyName` is already used elsewhere, confirming the resolution path.)

- [ ] **Step 6: Update `ScoreCanvas.swift`**

Modify `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift`. Replace the existing bracket block (lines 102-117) with:

```swift
        StaffRenderer.drawBrackets(
            context: &context,
            system: system,
            metrics: metrics
        )
```

- [ ] **Step 7: Build & run the rendering tests**

Run: `swift build && swift test --filter BracketRenderingTests`
Expected: 4 tests PASS.

- [ ] **Step 8: Run the entire suite**

Run: `swift test 2>&1 | tail -30`
Expected: every test PASSes. The fixture changes from Task 7 will now exercise both renderers; visually verify nothing regressed by also inspecting the SwiftUI preview / Mac example app per the project's verification convention if you're set up for it.

- [ ] **Step 9: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Staves.swift \
        Sources/SheetMusicUI/Rendering/ScoreLayerBuilder.swift \
        Sources/SheetMusicUI/Rendering/StaffRenderer.swift \
        Sources/SheetMusicUI/Rendering/ScoreCanvas.swift \
        Tests/SheetMusicTests/BracketRenderingTests.swift
git commit -m "feat(ui): drawBrackets dispatches per BracketType (brace/normal/square/line)"
```

---

## Task 9: Final pass — lint and full-suite green

**Files:** none (verification only).

- [ ] **Step 1: Run SwiftLint**

Run: `swiftlint --quiet Sources Tests 2>&1 | tail -20`
Expected: 0 warnings, 0 errors. If new files exceed the 300-line cap, split per-renderer helpers into `+Brackets.swift` extension files.

- [ ] **Step 2: Run the full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: every test PASSes.

- [ ] **Step 3: Visual verification (manual, optional)**

If on macOS with the example app set up, build & run `SheetMusicExampleMac` against the `multiPartMixedStaves` fixture and confirm:
- Vln1+Vln2 are joined by a thick NORMAL bracket on the outer column.
- Vln1+Vln2 also have a thin SQUARE bracket nested one column inward.
- Piano grand staff has a curly BRACE drawn from a Bravura glyph, vertically scaled to span both staves.
- Piano shows ONE "Piano" label vertically centered between its two staves (not two labels).
- Vc has no bracket and one "Violoncello" label.

If something looks off, flag it before declaring the work complete — preview snapshots are faster than re-running this whole loop later.

- [ ] **Step 4: Commit (only if anything was tweaked above)**

If lint or visual review surfaced fixes, commit them as a small follow-up:

```bash
git add -p   # interactively pick the cleanup chunks
git commit -m "chore: cleanup after bracket rendering pass"
```

If nothing changed, skip.

---

## Self-Review Notes

This plan was checked against the spec on completion:

- **Spec sections covered:** Core model (Tasks 1+2), MSCX reader (Task 3), `LayoutSystem` field (Task 4), Part labels — per-Part collapse (Task 5), Bracket geometry (Task 6), Updated fixture (Task 7), Rendering — including brace SMuFL glyph (Task 8), Updated test (LayoutPartLabelClefTests, Task 5), New tests (BracketDecodingTests, LayoutBracketTests, BracketRenderingTests across Tasks 3/6/8), Updated init sites (Task 4 — Spanners/Ties/shift; SystemBuild emits in Task 6).
- **Out-of-scope items intentionally left out:** auto-derivation from instrument family (`Score::updateBracesAndBarlines`), bracket editing UI, custom bracket colors, instruments.xml bundling.
- **Type-name consistency:** `BracketType`, `BracketItem`, `LayoutBracket`, `Staff.brackets`, `LayoutSystem.brackets`, `drawBrackets` — used identically across all tasks.
- **Spec ambiguity flagged:** the spec mentions the PDF renderer (`SheetMusicPDF`) updates as well; the current repo only has PDF *import* code, no PDF *export*, so the rendering update is confined to `SheetMusicUI`. The plan documents this in the file structure section. If a PDF exporter lands later, the same `LayoutBracket` data feeds it without further model changes.
