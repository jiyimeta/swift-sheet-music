# Element Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add MuseScore-style `<visible>` element visibility across the score model via a shared `ElementProperties` aggregate, with a `showsInvisibleElements` rendering toggle that greys hidden elements, while keeping MIDI playback unaffected.

**Architecture:** A new value type `ElementProperties` (SheetMusicCore) holds the per-element base properties (just `visible` for now). Each visibility-bearing element stores one `elementProperties` field plus a computed `visible` sugar. MSCX decode/encode go through two shared helpers on `ElementProperties` so future fields (colour, offset) attach in one place. Layout gains a `showsInvisibleElements` option; when false, hidden elements are dropped (today's behaviour); when true, they are emitted into a **parallel `invisibleElements` container** (not a new `LayoutElement` associated value) and both renderers (Canvas + CALayer) draw that container at 50 % opacity (= MuseScore's `#808080` on white). MIDI is never touched.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing (`@Test`/`#expect`), SwiftUI `GraphicsContext` + CoreAnimation `CALayer`, Foundation `XMLParser` (via `XMLTreeNode`).

---

## Working directory

All paths in this plan are relative to the worktree root:

```
/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/element-visibility
```

Branch: `feature/element-visibility`. The spec lives at
`docs/superpowers/specs/2026-05-28-element-visibility-design.md`.

## Verification commands (used throughout)

```bash
swift build
swift test                       # full suite — must stay 100 % green
swift test --filter <Name>       # a single test type/case
swiftlint --quiet Sources Tests  # optional; 0 warnings target (file length cap 300)
```

For Android-affecting changes (Core / MSCX targets), additionally:

```bash
Scripts/gate-android-tests.sh    # guards new Apple-importing tests with #if !os(Android)
```

Run `Scripts/gate-android-tests.sh` after creating **any** new test file that
imports `SheetMusicLayout` / `SheetMusicUI` / `SheetMusicPDF` or an Apple
framework.

---

## Shared recipes (read once; each task quotes its own concrete edits)

These three recipes recur. They are shown in full here; every task that
applies one quotes the exact per-type lines so tasks remain self-contained.

### Recipe A — migrate / add visibility to a Score type

For a `struct T` in `Sources/SheetMusicCore/Score/T.swift`:

1. Add the stored aggregate and the `visible` sugar:

```swift
/// Base element properties shared with every engravable element.
/// Currently carries only `<visible>`; see `ElementProperties`.
public var elementProperties: ElementProperties
/// Hidden from rendered/printed output (`<visible>0</visible>`).
/// Playback / MIDI is unaffected. Sugar over `elementProperties.visible`.
public var visible: Bool {
    get { elementProperties.visible }
    set { elementProperties.visible = newValue }
}
```

2. Keep the init's `visible: Bool = true` parameter (ergonomic; existing
   call sites unchanged). In the init body set:

```swift
self.elementProperties = ElementProperties(visible: visible)
```

   - For a type that did **not** previously have visibility, add the
     `visible: Bool = true` parameter at the end of the init parameter list
     (after the last existing defaulted parameter), so existing positional
     and trailing-default call sites still compile.

### Recipe B — MSCX decode / encode through the shared helpers

In the decoder (`Sources/SheetMusicMSCX/Decoders/MSCXDecoder+T.swift`):

- Drop any hand-rolled `let visible = (node.first("visible")?.text ?? "1") != "0"`.
- After constructing the value, assign the whole aggregate:

```swift
var result = T(/* existing args, no `visible:` */)
result.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
return result
```

In the encoder (`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+T.swift`):

- Drop any hand-rolled `if !visible { children.append(...) }`.
- Append the helper's output where `<visible>` belongs (immediately before
  `properties.appendXML(to:)` when the type has text properties, else just
  before the closing `return XMLTreeNode(...)`):

```swift
children.append(contentsOf: elementProperties.mscxChildren())
```

**Exceptions (do NOT use Recipe B; migrate storage only, keep bespoke I/O):**
- **Spanner** — visibility is derived from payload presence
  (`decodeVisible`) and the encoder inverts visibility into `<prev>` vs
  payload. Keep that logic; just route it through `elementProperties`.
- **BracketItem** — `<visible>` is an XML *attribute* on `<bracket>`, not a
  child element. Keep the attribute read/write; just store via
  `elementProperties`.

### Recipe C — honour visibility in layout placement

At each source-element placement site that currently does
`if !x.visible { break }`, replace with: build the `LayoutElement`, then
route it by visibility into the visible `out` array or the parallel
`invisibleOut` array, gated by `ctx.options.showsInvisibleElements`:

```swift
case let .tempo(t):
    guard t.visible || ctx.options.showsInvisibleElements else { break }
    let element = LayoutElement.textMark(/* ... */)
    if t.visible { out.append(element) } else { invisibleOut.append(element) }
```

When `showsInvisibleElements == false`, hidden elements are dropped exactly
as today. When `true`, they go to `invisibleOut`, which the system-build
pass stores in `LayoutMeasure.invisibleElements` (or, for spanners,
`LayoutSystem.invisibleSpanners`).

---

# Phase 0 — Foundation

Builds `ElementProperties`, the shared MSCX helpers, migrates the six
existing visibility types, and wires `showsInvisibleElements` end-to-end
through layout and both renderers — using only the six already-supported
types so the plumbing is proven before coverage expands. Independently
mergeable.

### Task 0.1: `ElementProperties` value type (SheetMusicCore)

**Files:**
- Create: `Sources/SheetMusicCore/Score/ElementProperties.swift`
- Test: `Tests/SheetMusicTests/ElementPropertiesTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/ElementPropertiesTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite struct ElementPropertiesTests {
    @Test func defaultIsVisible() {
        #expect(ElementProperties.default.visible == true)
        #expect(ElementProperties().visible == true)
    }

    @Test func initStoresVisible() {
        #expect(ElementProperties(visible: false).visible == false)
    }

    @Test func equatable() {
        #expect(ElementProperties(visible: true) == ElementProperties())
        #expect(ElementProperties(visible: false) != ElementProperties())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ElementPropertiesTests`
Expected: FAIL — `cannot find 'ElementProperties' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SheetMusicCore/Score/ElementProperties.swift`:

```swift
import Foundation

/// Properties shared by all engravable elements — the subset of
/// MuseScore's base `EngravingItem` persisted state this library models.
/// Deliberately a struct (not an OptionSet): the upstream base set is
/// mostly non-visual (offset, autoplace, placement, part-linking, …) and
/// keeps growing, so value-typed fields must be addable here later.
/// C++: mu::engraving::EngravingItem base properties (subset).
public struct ElementProperties: Sendable, Equatable {
    /// Hidden from rendered/printed output. MuseScore
    /// `ElementFlag::INVISIBLE` / `<visible>0</visible>`. Default true.
    /// Playback (MIDI) is unaffected — sounding is governed elsewhere
    /// (e.g. `Note.play`).
    public var visible: Bool

    // Reserved extension points (NOT implemented in this work):
    //   public var color: ScoreColor?      // <color>
    //   public var offset: ...             // <offset>
    //   public var autoplace / placement   // behavioural

    public init(visible: Bool = true) { self.visible = visible }
    public static let `default` = ElementProperties()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ElementPropertiesTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Gate + commit**

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicCore/Score/ElementProperties.swift Tests/SheetMusicTests/ElementPropertiesTests.swift
git commit -m "feat(core): add ElementProperties aggregate (visible)"
```

---

### Task 0.2: Shared MSCX decode/encode helpers (SheetMusicMSCX)

**Files:**
- Create: `Sources/SheetMusicMSCX/Decoders/ElementProperties+MSCX.swift`
- Test: `Tests/SheetMusicTests/ElementPropertiesMSCXTests.swift`

> Note: the parsed-tree node type *is* `XMLTreeNode` (there is no separate
> `XMLNode`); it serves both reading and writing. The spec's `XMLNode`
> reference is corrected to `XMLTreeNode` here.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/ElementPropertiesMSCXTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite struct ElementPropertiesMSCXTests {
    @Test func decodeMissingVisibleIsTrue() {
        let node = XMLTreeNode(name: "Tempo")
        #expect(ElementProperties(decodingMSCXChildrenOf: node).visible == true)
    }

    @Test func decodeVisibleZeroIsFalse() {
        let node = XMLTreeNode(
            name: "Tempo",
            children: [XMLTreeNode(name: "visible", text: "0")],
        )
        #expect(ElementProperties(decodingMSCXChildrenOf: node).visible == false)
    }

    @Test func encodeVisibleTrueEmitsNothing() {
        #expect(ElementProperties(visible: true).mscxChildren().isEmpty)
    }

    @Test func encodeVisibleFalseEmitsTag() {
        let out = ElementProperties(visible: false).mscxChildren()
        #expect(out.count == 1)
        #expect(out.first?.name == "visible")
        #expect(out.first?.text == "0")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ElementPropertiesMSCXTests`
Expected: FAIL — no `init(decodingMSCXChildrenOf:)` / `mscxChildren()`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SheetMusicMSCX/Decoders/ElementProperties+MSCX.swift`:

```swift
import SheetMusicCore
import SheetMusicXMLTools

extension ElementProperties {
    /// Reads the base element properties (`<visible>`, future `<color>`, …)
    /// from an element node. Missing `<visible>` defaults to visible.
    init(decodingMSCXChildrenOf node: XMLTreeNode) {
        self.init(visible: (node.first("visible")?.text ?? "1") != "0")
    }

    /// Emits the base element child tags. `<visible>0</visible>` only when
    /// hidden (the default — visible — omits the tag, matching MuseScore).
    func mscxChildren() -> [XMLTreeNode] {
        var out: [XMLTreeNode] = []
        if !visible { out.append(XMLTreeNode(name: "visible", text: "0")) }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ElementPropertiesMSCXTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Gate + commit**

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicMSCX/Decoders/ElementProperties+MSCX.swift Tests/SheetMusicTests/ElementPropertiesMSCXTests.swift
git commit -m "feat(mscx): add shared ElementProperties decode/encode helpers"
```

---

### Task 0.3: Migrate `Tempo` to `elementProperties`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Tempo.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Tempo.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Tempo.swift`

This is the first migration; it proves Recipes A + B. The public API
(`Tempo(... visible:)` and `.visible`) stays source-compatible, so existing
tests are the regression guard — no new test needed for this task.

- [ ] **Step 1: Edit the model**

In `Sources/SheetMusicCore/Score/Tempo.swift`, replace the stored field
(lines 18–21):

```swift
    /// MuseScore `<visible>0</visible>` flag. When false the tempo
    /// label is hidden — layout drops it (no glyph, no reserved
    /// space) but the tempo change still applies to playback / MIDI.
    public var visible: Bool
```

with:

```swift
    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. When false the tempo
    /// label is hidden — layout drops it (no glyph, no reserved
    /// space) but the tempo change still applies to playback / MIDI.
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }
```

In the init body, replace `self.visible = visible` with:

```swift
        self.elementProperties = ElementProperties(visible: visible)
```

(The init signature keeps `visible: Bool = true,` unchanged.)

- [ ] **Step 2: Edit the decoder**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Tempo.swift`, delete the
line:

```swift
    let visible = (node.first("visible")?.text ?? "1") != "0"
```

Change the construction from:

```swift
    return Tempo(
        beatsPerSecond: bps,
        offsetX: offset.0,
        offsetY: offset.1,
        properties: TextProperties.decode(node),
        visible: visible,
    )
```

to:

```swift
    var tempo = Tempo(
        beatsPerSecond: bps,
        offsetX: offset.0,
        offsetY: offset.1,
        properties: TextProperties.decode(node),
    )
    tempo.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
    return tempo
```

- [ ] **Step 3: Edit the encoder**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Tempo.swift`, replace:

```swift
    if !visible {
        children.append(XMLTreeNode(name: "visible", text: "0"))
    }
```

with:

```swift
    children.append(contentsOf: elementProperties.mscxChildren())
```

- [ ] **Step 4: Build + run the full suite (regression)**

Run: `swift build && swift test`
Expected: PASS — existing Tempo / round-trip tests unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/Tempo.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Tempo.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Tempo.swift
git commit -m "refactor(core): migrate Tempo visibility to ElementProperties"
```

---

### Task 0.4: Migrate `StaffText`, `Harmony`, `Swing` (child-`<visible>` types)

These three follow Recipe A + B exactly like `Tempo`. Apply the identical
mechanical edits per type.

**Files:**
- Modify: `Sources/SheetMusicCore/Score/StaffText.swift`, `Harmony.swift`, `Swing.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffText.swift`, `+Harmony.swift`, `+Swing.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+StaffText.swift`, `+Harmony.swift`, `+Swing.swift`

- [ ] **Step 1: Model edits (each of StaffText, Harmony, Swing)**

In each `Sources/SheetMusicCore/Score/<T>.swift`, replace the stored
`public var visible: Bool` with the `elementProperties` field + `visible`
computed sugar (Recipe A, verbatim block):

```swift
    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }
```

and in each init body replace `self.visible = visible` with:

```swift
        self.elementProperties = ElementProperties(visible: visible)
```

- [ ] **Step 2: Decoder edits (each of +StaffText, +Harmony, +Swing)**

In each decoder, delete the `let visible = (node.first("visible")?.text ?? "1") != "0"`
line, drop the `visible: visible,` argument from the `return <T>(...)` call,
bind the result to a `var`, assign the aggregate, and return it. For
`StaffText`:

```swift
    var staffText = StaffText(
        text: text,
        offsetX: offset.0,
        offsetY: offset.1,
        color: color,
        isSystemText: isSystemText,
        properties: props,
    )
    staffText.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
    return staffText
```

For `Harmony` (bind `harmony`) and `Swing` (bind `swing`), apply the same
transform to their respective `return Harmony(...)` / `return Swing(...)`
calls, dropping `visible: visible,` and appending the
`.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)` line
before `return`.

- [ ] **Step 3: Encoder edits (each of +StaffText, +Harmony, +Swing)**

In each encoder, replace the:

```swift
    if !visible {
        children.append(XMLTreeNode(name: "visible", text: "0"))
    }
```

block with:

```swift
    children.append(contentsOf: elementProperties.mscxChildren())
```

(keeping it in the same position — before `properties.appendXML(to:)`).

- [ ] **Step 4: Build + run the full suite (regression)**

Run: `swift build && swift test`
Expected: PASS — existing StaffText/Harmony/Swing round-trip tests
unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/StaffText.swift Sources/SheetMusicCore/Score/Harmony.swift Sources/SheetMusicCore/Score/Swing.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffText.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Harmony.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Swing.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+StaffText.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Harmony.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Swing.swift
git commit -m "refactor(core): migrate StaffText/Harmony/Swing visibility to ElementProperties"
```

---

### Task 0.5: Migrate `Spanner` + `BracketItem` (bespoke-I/O exceptions)

Both migrate storage to `elementProperties` but keep their special decode /
encode logic (Recipe B exceptions).

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Spanner.swift`, `BracketItem.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift`, `MSCXDecoder+Staff.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift`, `MSCXEncoder+Staff.swift`

- [ ] **Step 1: Model edits**

In `Spanner.swift` and `BracketItem.swift`, apply Recipe A: replace stored
`public var visible: Bool` with the `elementProperties` field + `visible`
computed sugar, and in the init body replace `self.visible = visible` with
`self.elementProperties = ElementProperties(visible: visible)`. Keep the
`visible: Bool = true` init parameter.

- [ ] **Step 2: Decoder edits (keep bespoke logic)**

`MSCXDecoder+Spanner.swift` already computes visibility via
`decodeVisible(node)` and passes `visible: decodeVisible(node)`. Leave that
call **as-is** — the `visible:` init param still works (it now writes
through `elementProperties`). No change needed beyond confirming it builds.

`MSCXDecoder+Staff.swift` reads the attribute
`let visible = (el.attributes["visible"] ?? "1") != "0"` and passes
`visible: visible` to `BracketItem(...)`. Leave **as-is** for the same
reason.

- [ ] **Step 3: Encoder edits (keep bespoke logic)**

`MSCXEncoder+Spanner.swift` branches on `if visible { ... } else { ... }`
to emit payload vs `<prev>`. The `visible` accessor still resolves through
the sugar — leave **as-is**.

`MSCXEncoder+Staff.swift` writes `if !bracket.visible { bracketAttrs["visible"] = "0" }`.
The `.visible` sugar still resolves — leave **as-is**.

(No I/O code changes; this task is purely the storage migration. The build
confirms the sugar satisfies all existing call sites.)

- [ ] **Step 4: Build + run the full suite (regression)**

Run: `swift build && swift test`
Expected: PASS — existing Spanner / bracket round-trip tests unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/Spanner.swift Sources/SheetMusicCore/Score/BracketItem.swift
git commit -m "refactor(core): migrate Spanner/BracketItem visibility storage to ElementProperties"
```

---

### Task 0.6: Add `showsInvisibleElements` to `ScoreViewOptions` + `RenderContext`

**Files:**
- Modify: `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine.swift` (RenderContext, ~lines 348–382, and where RenderContext is constructed)
- Test: `Tests/SheetMusicTests/ShowsInvisibleOptionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/ShowsInvisibleOptionTests.swift`:

```swift
#if !os(Android)
@testable import SheetMusicLayout
import Testing

@Suite struct ShowsInvisibleOptionTests {
    @Test func defaultsToFalse() {
        #expect(ScoreViewOptions().showsInvisibleElements == false)
    }

    @Test func canEnable() {
        var opts = ScoreViewOptions()
        opts.showsInvisibleElements = true
        #expect(opts.showsInvisibleElements == true)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ShowsInvisibleOptionTests`
Expected: FAIL — `value of type 'ScoreViewOptions' has no member 'showsInvisibleElements'`.

- [ ] **Step 3: Add the option**

In `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`, add a stored
property to the struct (after `multiMeasureRest`):

```swift
    /// MuseScore "Show Invisible". When true, elements with
    /// `visible == false` are still laid out and tagged invisible so
    /// renderers grey them (`#808080`). When false (print behaviour),
    /// invisible elements are dropped entirely. Default false.
    public var showsInvisibleElements: Bool
```

Add the matching init parameter (last, defaulted) and assignment:

```swift
        showsInvisibleElements: Bool = false,
```

```swift
        self.showsInvisibleElements = showsInvisibleElements
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ShowsInvisibleOptionTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Confirm RenderContext exposes options**

`RenderContext` already holds `let options: ScoreViewOptions` (LayoutEngine.swift
~line 350), so placement passes read `ctx.options.showsInvisibleElements`
directly — no RenderContext change needed. Verify with:

Run: `rg -n 'let options: ScoreViewOptions' Sources/SheetMusicLayout/Layout/LayoutEngine.swift`
Expected: one match inside `struct RenderContext`.

- [ ] **Step 6: Commit**

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicLayout/Options/ScoreViewOptions.swift Tests/SheetMusicTests/ShowsInvisibleOptionTests.swift
git commit -m "feat(layout): add showsInvisibleElements option (default false)"
```

---

### Task 0.7: Add invisible containers to `LayoutMeasure` + `LayoutSystem`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutMeasure.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutSystem.swift`
- Test: `Tests/SheetMusicTests/InvisibleContainerTests.swift`

New fields are defaulted to `[]` in the init so the four existing
`LayoutMeasure(...)` / five `LayoutSystem(...)` construction sites compile
unchanged.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/InvisibleContainerTests.swift`:

```swift
#if !os(Android)
import CoreGraphics
@testable import SheetMusicLayout
import Testing

@Suite struct InvisibleContainerTests {
    @Test func measureDefaultsToEmptyInvisible() {
        let m = LayoutMeasure(
            measureIndex: 0, origin: .zero, width: 10, elements: [],
        )
        #expect(m.invisibleElements.isEmpty)
    }

    @Test func systemDefaultsToEmptyInvisibleSpanners() {
        let s = LayoutSystem(
            origin: .zero,
            size: CGSize(width: 10, height: 10),
            measures: [],
            staffOrigins: [],
            partLabels: [],
            spanners: [],
            sp: 4,
        )
        #expect(s.invisibleSpanners.isEmpty)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter InvisibleContainerTests`
Expected: FAIL — no `invisibleElements` / `invisibleSpanners` members.

- [ ] **Step 3: Add the fields**

In `Sources/SheetMusicLayout/Layout/LayoutMeasure.swift`, add a stored
property after `multiMeasureRest`:

```swift
    /// Elements whose source is hidden (`visible == false`) but emitted
    /// anyway because `showsInvisibleElements` is on. Renderers draw these
    /// at 50 % opacity (MuseScore `#808080` on white). Empty in print
    /// layout. Origins follow the same convention as `elements`.
    public let invisibleElements: [LayoutElement]
```

Add the matching init parameter (after `multiMeasureRest: Int? = nil,`):

```swift
        invisibleElements: [LayoutElement] = [],
```

and assignment in the init body:

```swift
        self.invisibleElements = invisibleElements
```

In `Sources/SheetMusicLayout/Layout/LayoutSystem.swift`, add after
`spanners`:

```swift
    /// System-level spanner segments whose source is hidden but emitted
    /// because `showsInvisibleElements` is on. Drawn at 50 % opacity.
    public let invisibleSpanners: [LayoutElement]
```

Add the init parameter (after `spanners: [LayoutElement],`):

```swift
        invisibleSpanners: [LayoutElement] = [],
```

and assignment:

```swift
        self.invisibleSpanners = invisibleSpanners
```

- [ ] **Step 4: Run test + full build (existing call sites must still compile)**

Run: `swift build && swift test --filter InvisibleContainerTests`
Expected: PASS (2 tests); build succeeds — all existing
`LayoutMeasure(...)` / `LayoutSystem(...)` call sites use the defaults.

- [ ] **Step 5: Commit**

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicLayout/Layout/LayoutMeasure.swift Sources/SheetMusicLayout/Layout/LayoutSystem.swift Tests/SheetMusicTests/InvisibleContainerTests.swift
git commit -m "feat(layout): add invisibleElements / invisibleSpanners containers"
```

---

### Task 0.8: Route hidden annotations into the invisible container (placement)

Wire the existing `if !x.visible { break }` sites to emit into a parallel
`invisibleOut` array when `showsInvisibleElements` is on, and thread that
array up to `LayoutMeasure.invisibleElements` / `LayoutSystem.invisibleSpanners`.

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`
  (placement entry `placeMeasureElements`, ~line 44; sites at ~958 harmony, ~1435 tempo, ~1451 staffText, ~1464 swing)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift`
  (where `placeMeasureElements` results become `LayoutMeasure`, ~lines 603/626/716)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift`
  (spanner collection skip at ~line 75; where spanner segments become `LayoutSystem.spanners`)
- Test: `Tests/SheetMusicTests/InvisibleLayoutTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/InvisibleLayoutTests.swift`. Build a minimal
one-measure score with a hidden `Tempo` and assert routing under both
toggle states:

```swift
#if !os(Android)
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite struct InvisibleLayoutTests {
    /// A one-staff, one-measure score whose measure carries a hidden tempo.
    private func scoreWithHiddenTempo() -> Score {
        var tempo = Tempo(beatsPerSecond: 2.0)
        tempo.visible = false
        // Construct the smallest valid Score with one measure that
        // contains `tempo` as a voice element. (Use the same helpers the
        // existing layout tests use — see Tests/SheetMusicTests/Helpers.)
        return TestScores.singleMeasure(extraVoiceElements: [.tempo(tempo)])
    }

    private func tempoMarks(_ doc: LayoutDocument) -> [LayoutElement] {
        doc.systems.flatMap(\.measures).flatMap(\.elements)
            .filter { if case .textMark(.tempo, _, _) = $0 { true } else { false } }
    }

    private func invisibleTempoMarks(_ doc: LayoutDocument) -> [LayoutElement] {
        doc.systems.flatMap(\.measures).flatMap(\.invisibleElements)
            .filter { if case .textMark(.tempo, _, _) = $0 { true } else { false } }
    }

    @Test func hiddenTempoDroppedWhenToggleOff() {
        let doc = LayoutEngine.layout(
            score: scoreWithHiddenTempo(),
            options: ScoreViewOptions(showsInvisibleElements: false),
            availableWidth: 800,
        )
        #expect(tempoMarks(doc).isEmpty)
        #expect(invisibleTempoMarks(doc).isEmpty)
    }

    @Test func hiddenTempoTaggedWhenToggleOn() {
        let doc = LayoutEngine.layout(
            score: scoreWithHiddenTempo(),
            options: ScoreViewOptions(showsInvisibleElements: true),
            availableWidth: 800,
        )
        #expect(tempoMarks(doc).isEmpty)             // not in the visible list
        #expect(invisibleTempoMarks(doc).count == 1) // tagged invisible
    }
}
#endif
```

> **Before writing the test body:** inspect `Tests/SheetMusicTests/Helpers/`
> for an existing single-measure score builder (the layout tests already
> construct minimal scores). Reuse it; if its API differs from
> `TestScores.singleMeasure(extraVoiceElements:)` above, adapt the two
> helper calls to the real builder. Do not invent a new fixture file.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter InvisibleLayoutTests`
Expected: FAIL — `hiddenTempoTaggedWhenToggleOn` finds 0 invisible marks
(routing not implemented; element is currently dropped by `if !t.visible { break }`).

- [ ] **Step 3: Thread an `invisibleOut` array through `placeMeasureElements`**

In `LayoutEngine+Placement.swift`, change the return tuple of
`placeMeasureElements` (line 66) from:

```swift
    ) -> (elements: [LayoutElement], clef: NotatedClef, key: Int) {
```

to:

```swift
    ) -> (
        elements: [LayoutElement],
        invisibleElements: [LayoutElement],
        clef: NotatedClef,
        key: Int,
    ) {
```

Inside the function, declare `var invisibleOut: [LayoutElement] = []`
alongside the existing `out` accumulator, and return it in the tuple.

- [ ] **Step 4: Apply Recipe C at each annotation site**

For each of the four sites, replace `if !x.visible { break }` + unconditional
`out.append(element)` with the route-by-visibility form. Tempo (~line 1435):

```swift
case let .tempo(t):
    guard t.visible || ctx.options.showsInvisibleElements else { break }
    let bpm = Int((t.beatsPerSecond * 60.0).rounded())
    let element = LayoutElement.textMark(
        kind: .tempo,
        text: "\u{E1D5} = \(bpm)",
        origin: CGPoint(/* unchanged */),
    )
    if t.visible { out.append(element) } else { invisibleOut.append(element) }
```

StaffText (~1451) and Swing (~1464): build the `.staffText(...)` element
into a local `let element`, then
`if x.visible { out.append(element) } else { invisibleOut.append(element) }`,
gated by the same `guard x.visible || ctx.options.showsInvisibleElements else { break }`.
Harmony (~958): the harmony case currently `break`s *before* measurement to
exclude it from spacing. Keep that spacing exclusion (hidden harmony must
not widen the bar), but when `showsInvisibleElements` is on, still build the
`LayoutHarmony` and append it to `invisibleOut` after the spacing-affecting
work — i.e. route it to `invisibleOut` without feeding it into the
pre-spacing/autoplace pass. If the harmony element is produced later in the
pass, append there into `invisibleOut`.

> Harmony note: harmony layout is the most entangled with spacing. If
> routing it cleanly into `invisibleOut` without affecting spacing proves
> non-trivial, defer **harmony only** to a follow-up and keep its current
> `if !harmony.visible { break }` — record the deferral in the commit
> message. Tempo/StaffText/Swing must land in this task.

- [ ] **Step 5: Carry `invisibleElements` into `LayoutMeasure`**

In `LayoutEngine+SystemBuild.swift`, at each place that destructures the
`placeMeasureElements` result and builds a `LayoutMeasure` (~lines 603, 626,
716), capture the new `invisibleElements` field and pass it to the
`LayoutMeasure(...)` initializer:

```swift
let placed = placeMeasureElements(/* ... */)
// ...
layoutMeasures.append(LayoutMeasure(
    /* existing args ... */,
    elements: placed.elements,
    /* ... */,
    invisibleElements: placed.invisibleElements,
))
```

Adjust the existing destructuring (e.g. `let (elements, clef, key) = ...`)
to include the new tuple element.

- [ ] **Step 6: Route hidden spanners (LayoutEngine+Spanners.swift)**

In `collectSpanners` (~line 75) the loop skips hidden spanners with
`if case let .spanner(sp) = el, sp.visible { … }`. Add a parallel collection
of hidden spanner anchors when `showsInvisibleElements` is on, lay them out
the same way, and pass the resulting segments to
`LayoutSystem(..., invisibleSpanners: …)` at the `LayoutSystem(...)`
construction sites that this file feeds. If `showsInvisibleElements` is
threaded into `collectSpanners` is awkward (it currently takes only
`score`), add the option as a parameter and pass `ctx.options.showsInvisibleElements`
from the caller.

> If spanner routing is structurally awkward in this task, it may be split
> into its own follow-up commit within Phase 0 — annotations
> (tempo/staffText/swing) are the required deliverable; spanners and harmony
> may follow. Do not block the phase on them.

- [ ] **Step 7: Run test to verify it passes**

Run: `swift test --filter InvisibleLayoutTests && swift build && swift test`
Expected: PASS — `hiddenTempoTaggedWhenToggleOn` finds exactly 1 invisible
tempo mark; full suite green.

- [ ] **Step 8: Commit**

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift Sources/SheetMusicLayout/Layout/LayoutEngine+Spanners.swift Tests/SheetMusicTests/InvisibleLayoutTests.swift
git commit -m "feat(layout): route hidden annotations into invisible container under showsInvisibleElements"
```

---

### Task 0.9: Canvas renderer — draw invisible container at 50 % opacity

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift` (`drawSystem`, ~lines 142–188)

The `GraphicsContext` value type carries an `opacity: Double`; drawing the
invisible elements through a copy with `opacity = 0.5` yields `#808080` on
the white background — the exact equivalent used by `StickyHeaderView`.

- [ ] **Step 1: Draw invisible measure elements**

In `ScoreCanvas.swift` `drawSystem`, inside the `for measure in system.measures`
loop, after the existing `for element in measure.elements { drawElement(...) }`
block (line ~161), add:

```swift
            if !measure.invisibleElements.isEmpty {
                var grey = context
                grey.opacity = 0.5
                for element in measure.invisibleElements {
                    drawElement(
                        element,
                        base: base,
                        metrics: metrics,
                        into: &grey,
                    )
                }
            }
```

- [ ] **Step 2: Draw invisible spanners**

After the existing system-level spanner loop (line ~187), add:

```swift
        if !system.invisibleSpanners.isEmpty {
            var grey = context
            grey.opacity = 0.5
            for el in system.invisibleSpanners {
                drawElement(
                    el,
                    base: system.origin,
                    metrics: metrics,
                    into: &grey,
                )
            }
        }
```

- [ ] **Step 3: Build (and run any Canvas snapshot tests)**

Run: `swift build && swift test`
Expected: PASS — build succeeds; existing rendering tests unchanged
(invisible containers are empty unless `showsInvisibleElements` is on).

- [ ] **Step 4: Visual verification (manual, deferred to phase review)**

Note for the reviewer: visual confirmation of greying uses the Mac example
app (`SheetMusicExampleMac`) with `showsInvisibleElements` toggled on — see
the project's visual-verification preference. Not gated by an automated test.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/ScoreCanvas.swift
git commit -m "feat(ui): Canvas renderer greys invisible elements at 50% opacity"
```

---

### Task 0.10: CALayer renderer — draw invisible container into a 50 %-opacity layer

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder.swift` (`buildSystemWithItems`, ~lines 65–131)

Mirror the Canvas change in the CALayer path (dual-renderer parity rule —
this must land in both or invisible elements render inconsistently). Build
the invisible elements into a dedicated child `CALayer` whose `opacity` is
`0.5`, added on top of `root`.

- [ ] **Step 1: Build invisible elements into a half-opacity sublayer**

In `buildSystemWithItems`, after the `for measure in system.measures` loop
and the `for el in system.spanners` loop (after line ~129, before
`return (root, ctx.items)`), add:

```swift
        let hasInvisible = system.measures.contains { !$0.invisibleElements.isEmpty }
            || !system.invisibleSpanners.isEmpty
        if hasInvisible {
            let invisibleLayer = CALayer()
            invisibleLayer.frame = root.bounds
            invisibleLayer.opacity = 0.5
            invisibleLayer.masksToBounds = false
            for measure in system.measures where !measure.invisibleElements.isEmpty {
                let base = CGPoint(x: measure.origin.x, y: measure.origin.y)
                for element in measure.invisibleElements {
                    drawElement(
                        element, base: base,
                        metrics: metrics, height: height,
                        context: &ctx, into: invisibleLayer,
                    )
                }
            }
            for el in system.invisibleSpanners {
                drawElement(
                    el, base: .zero,
                    metrics: metrics, height: height,
                    context: &ctx, into: invisibleLayer,
                )
            }
            root.addSublayer(invisibleLayer)
        }
```

> Note: the elements are still registered in `ctx.items` for selection, but
> since invisible elements are not interactively selectable in this work
> that is harmless. If selection re-tinting on an invisible element looks
> wrong during review, exclude invisible elements from `ctx` by passing a
> throwaway `BuildContext` — note this as a possible follow-up.

- [ ] **Step 2: Build (and run CALayer tests)**

Run: `swift build && swift test`
Expected: PASS — build succeeds; existing tests unchanged.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/ScoreLayerBuilder.swift
git commit -m "feat(ui): CALayer renderer greys invisible elements via 50% opacity layer"
```

---

### Task 0.11: MIDI invariant regression test

Lock in that visibility never affects MIDI: flipping `visible` on score
elements produces byte-identical SMF output.

**Files:**
- Test: `Tests/SheetMusicTests/VisibilityMidiInvariantTests.swift`

- [ ] **Step 1: Write the test**

Create `Tests/SheetMusicTests/VisibilityMidiInvariantTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct VisibilityMidiInvariantTests {
    @Test func hidingTempoDoesNotChangeSMFBytes() throws {
        // Parse an existing fixture that contains a Tempo, render to SMF,
        // then hide every Tempo and render again. Bytes must match.
        let score = try TestScores.parseFixture("midi01")  // adapt to a
        // fixture known to contain a <tempo>; reuse the MidiExportTests path.

        let before = try MidiRenderer.render(score: score).encoded()

        var hidden = score
        hidden.mutateEveryTempo { $0.visible = false }   // adapt to model
        let after = try MidiRenderer.render(score: hidden).encoded()

        #expect(before == after)
    }
}
```

> **Adapt to the real API:** inspect `Tests/SheetMusicTests/` (especially
> `MidiExportTests` and `Helpers/`) for the exact fixture-parse + render +
> encode calls already in use, and for how to walk/mutate `Score`'s staves
> → measures → voices → elements to flip `visible` on `Tempo` (and, once
> Phase 1 lands, on a `Dynamic`). Replace the pseudo-helpers
> (`TestScores.parseFixture`, `mutateEveryTempo`) with the real calls. The
> assertion `before == after` on the encoded `[UInt8]` is the invariant.

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter VisibilityMidiInvariantTests`
Expected: PASS — bytes identical (MidiRenderer never reads `visible`).

- [ ] **Step 3: Commit**

```bash
Scripts/gate-android-tests.sh
git add Tests/SheetMusicTests/VisibilityMidiInvariantTests.swift
git commit -m "test(midi): assert visibility never changes SMF output"
```

---

### Task 0.12: PDF export uses print behaviour (no greying)

PDF export must always lay out with `showsInvisibleElements == false`.

**Files:**
- Modify: `Sources/SheetMusicPDF/PDFExporter.swift` (~line 97, `layoutOptions`)
- Test: `Tests/SheetMusicTests/PDFInvisibleTests.swift`

- [ ] **Step 1: Make the print behaviour explicit**

In `PDFExporter.swift`, the `ScoreViewOptions(...)` for `layoutOptions`
relies on the default `showsInvisibleElements: false`. Make it explicit for
intent (and to guard against the default ever changing):

```swift
        let layoutOptions = ScoreViewOptions(
            staffSize: resolved.staffSize,
            systemGap: options.systemGap,
            wrapToViewWidth: true,
            breakPolicy: options.breakPolicy,
            showsInvisibleElements: false,
        )
```

- [ ] **Step 2: Write the test**

Create `Tests/SheetMusicTests/PDFInvisibleTests.swift`:

```swift
#if !os(Android)
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicPDF
import Testing

@Suite struct PDFInvisibleTests {
    @Test func pdfLayoutDropsHiddenAnnotations() throws {
        // A score with a hidden tempo, laid out the way PDFExporter does.
        var tempo = Tempo(beatsPerSecond: 2.0)
        tempo.visible = false
        let score = TestScores.singleMeasure(extraVoiceElements: [.tempo(tempo)])

        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(showsInvisibleElements: false),
            availableWidth: 800,
        )
        let invisible = doc.systems.flatMap(\.measures)
            .flatMap(\.invisibleElements)
        #expect(invisible.isEmpty)  // print layout never tags invisibles
    }
}
#endif
```

(Adapt `TestScores.singleMeasure` to the real fixture helper, as in
Task 0.8.)

- [ ] **Step 3: Run + commit**

Run: `swift test --filter PDFInvisibleTests && swift build && swift test`
Expected: PASS; full suite green.

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicPDF/PDFExporter.swift Tests/SheetMusicTests/PDFInvisibleTests.swift
git commit -m "feat(pdf): export with showsInvisibleElements=false explicitly"
```

---

### Phase 0 verification gate

- [ ] `swift build` clean.
- [ ] `swift test` 100 % green.
- [ ] `Scripts/gate-android-tests.sh` reports new tests guarded.
- [ ] Android cross-build of Core + MSCX still resolves:
      `SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28`
      (requires `export TOOLCHAINS=org.swift.632202605101a` first).
- [ ] Manual: Mac example app with `showsInvisibleElements` on shows hidden
      tempo/staffText in grey; off shows nothing. (Phase review.)

Phase 0 is independently mergeable here.

---

# Phase 1 — Named elements: Note, Chord (= rest), Dynamic

Adds visibility to the most common elements. Notes are per-notehead; a
rest is an empty `Chord`. Glyph suppression preserves the rhythmic slot
(an invisible note leaves a gap, never collapses the bar).

### Task 1.1: Add `elementProperties` to `Dynamic`, `Note`, `Chord`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Dynamic.swift`, `Note.swift`, `Chord.swift`
- Test: `Tests/SheetMusicTests/Phase1ModelVisibilityTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/Phase1ModelVisibilityTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite struct Phase1ModelVisibilityTests {
    @Test func dynamicDefaultsVisible() {
        #expect(Dynamic(subtype: "mf", velocity: 80).visible == true)
    }

    @Test func noteVisibilitySugar() {
        var n = Note(pitch: 60, tpc: 14)
        #expect(n.visible == true)
        n.visible = false
        #expect(n.elementProperties.visible == false)
    }

    @Test func chordDefaultsVisible() {
        let c = Chord(duration: .quarter, notes: [])
        #expect(c.visible == true)
    }
}
```

(If `NoteDuration.quarter` / `.quarter` spelling differs, adapt to the real
`NoteDuration` API — check `Sources/SheetMusicCore/Score/NoteDuration.swift`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter Phase1ModelVisibilityTests`
Expected: FAIL — `Dynamic` / `Note` / `Chord` have no `visible`.

- [ ] **Step 3: Apply Recipe A to all three**

For `Dynamic`, `Note`, `Chord`: add the `elementProperties` stored field +
`visible` computed sugar (Recipe A block), add a trailing
`visible: Bool = true,` init parameter, and assign
`self.elementProperties = ElementProperties(visible: visible)` in the init
body. Place the field after the last existing stored property in each type
(e.g. after `play` in `Note`, after `velocity`/`properties` in `Dynamic`,
after `tremolo` in `Chord`).

- [ ] **Step 4: Run test + full build**

Run: `swift build && swift test --filter Phase1ModelVisibilityTests`
Expected: PASS (3 tests); full build clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/Score/Dynamic.swift Sources/SheetMusicCore/Score/Note.swift Sources/SheetMusicCore/Score/Chord.swift Tests/SheetMusicTests/Phase1ModelVisibilityTests.swift
git commit -m "feat(core): add visibility to Note/Chord/Dynamic"
```

---

### Task 1.2: MSCX decode/encode for Dynamic, Note, Chord, Rest

**Files:**
- Modify decoders: `MSCXDecoder+Dynamic.swift`, `+Note.swift`, `+Chord.swift`, `+Rest.swift`
- Modify encoders: `MSCXEncoder+Dynamic.swift`, `+Note.swift`, `+Chord.swift`
- Test: `Tests/SheetMusicTests/Phase1RoundTripTests.swift`

- [ ] **Step 1: Write the failing round-trip test**

Create `Tests/SheetMusicTests/Phase1RoundTripTests.swift`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite struct Phase1RoundTripTests {
    @Test func dynamicVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "Dynamic",
            children: [
                XMLTreeNode(name: "subtype", text: "f"),
                XMLTreeNode(name: "velocity", text: "96"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let dyn = try MSCXDynamicDecoder.decode(node)   // adapt decoder name
        #expect(dyn.visible == false)
        let reencoded = dyn.encode()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func dynamicVisibleTrueOmitsTag() throws {
        let dyn = Dynamic(subtype: "f", velocity: 96)
        #expect(dyn.encode().first("visible") == nil)
    }

    @Test func noteVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "Note",
            children: [
                XMLTreeNode(name: "pitch", text: "60"),
                XMLTreeNode(name: "tpc", text: "14"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let note = try MSCXNoteDecoder.decode(node)     // adapt decoder name
        #expect(note.visible == false)
        #expect(note.encode().first("visible")?.text == "0")
    }
}
```

> Adapt the decoder entry-point names to the real ones (the decoders use
> `static func decode(_:)` on per-type decoder enums/structs — confirm the
> exact type names with `rg 'func decode' Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Note.swift`).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter Phase1RoundTripTests`
Expected: FAIL — `visible` not decoded/encoded yet.

- [ ] **Step 3: Decoder edits (Recipe B)**

- `MSCXDecoder+Dynamic.swift`: bind `var dynamic = Dynamic(...)`, add
  `dynamic.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)`,
  `return dynamic`.
- `MSCXDecoder+Note.swift`: bind `var note = Note(...)` from the existing
  `return Note(...)`, add the `.elementProperties = …` line, `return note`.
- `MSCXDecoder+Chord.swift`: bind `var chord = Chord(...)`, add the
  `.elementProperties = …` line, `return chord`.
- `MSCXDecoder+Rest.swift`: the rest is `Chord(duration: duration, notes: [])`.
  Change to:
  ```swift
  var rest = Chord(duration: duration, notes: [])
  rest.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
  return rest
  ```

- [ ] **Step 4: Encoder edits (Recipe B)**

- `MSCXEncoder+Dynamic.swift`: before `properties.appendXML(to: &children)`
  add `children.append(contentsOf: elementProperties.mscxChildren())`.
- `MSCXEncoder+Note.swift`: before `return XMLTreeNode(name: "Note", children: children)`
  add the same `children.append(contentsOf: elementProperties.mscxChildren())`.
- `MSCXEncoder+Chord.swift` (`encodeAsChord`): before
  `return XMLTreeNode(name: "Chord", children: children)` add the same line.
  This covers both pitched chords and rests if rests are encoded through a
  chord/rest encoder; confirm the rest encode path — if rests have a
  dedicated `<Rest>` encoder, add the line there too. Run
  `rg -n 'name: "Rest"' Sources/SheetMusicMSCX/Encoders/` to locate it.

- [ ] **Step 5: Run test + full build**

Run: `swift test --filter Phase1RoundTripTests && swift build && swift test`
Expected: PASS; full suite green (including `MidiExportTests`).

- [ ] **Step 6: Commit**

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Dynamic.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Note.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Rest.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Dynamic.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift Tests/SheetMusicTests/Phase1RoundTripTests.swift
git commit -m "feat(mscx): round-trip visibility for Note/Chord/Rest/Dynamic"
```

---

### Task 1.3: Per-notehead invisibility flag on `LayoutChordNote`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift` (`LayoutChordNote`, ~lines 259–309)
- Test: `Tests/SheetMusicTests/LayoutChordNoteInvisibleTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
#if !os(Android)
import CoreGraphics
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite struct LayoutChordNoteInvisibleTests {
    @Test func defaultsVisible() {
        let n = LayoutChordNote(
            noteID: NoteID(measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndex: 0),
            step: 0, accidental: nil, origin: .zero,
            tieForward: nil, tieBack: nil, hasGlissando: false,
        )
        #expect(n.isInvisible == false)
    }
}
#endif
```

(Adapt the `NoteID(...)` initializer to the real one — check
`Sources/SheetMusicCore/Score/NoteID.swift`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LayoutChordNoteInvisibleTests`
Expected: FAIL — no `isInvisible` member.

- [ ] **Step 3: Add the flag**

In `LayoutChordNote`, add a stored property:

```swift
    /// True when this notehead's source `Note.visible == false` and the
    /// chord is being laid out with `showsInvisibleElements`. Renderers
    /// grey just this notehead. The slot is preserved regardless.
    public let isInvisible: Bool
```

Add `isInvisible: Bool = false,` as the final init parameter and assign
`self.isInvisible = isInvisible` in the init body.

- [ ] **Step 4: Run test + build (existing LayoutChordNote call sites use the default)**

Run: `swift build && swift test --filter LayoutChordNoteInvisibleTests`
Expected: PASS; build clean — the three existing `LayoutChordNote(...)`
construction sites (Placement.swift ~582, ~1551, ~1610) compile via the
default.

- [ ] **Step 5: Commit**

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicLayout/Layout/LayoutElement.swift Tests/SheetMusicTests/LayoutChordNoteInvisibleTests.swift
git commit -m "feat(layout): add isInvisible flag to LayoutChordNote"
```

---

### Task 1.4: Propagate note/chord visibility into placement

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`
  (chord-note construction ~582 and the mirror pass ~1551; chord/rest emission)
- Test: extend `Tests/SheetMusicTests/InvisibleLayoutTests.swift`

Rules (spec §6):
- Per-note: when a `Note.visible == false`, set `isInvisible: true` on its
  `LayoutChordNote`. The notehead is greyed (toggle on) or suppressed
  (toggle off) by the renderer; the slot/spacing is unchanged either way.
- Whole chord/rest hidden (the `Chord.visible == false`, or every note
  invisible): when the toggle is off, suppress the chord/rest glyphs
  (noteheads + stem/flag/beam) but keep the rhythmic slot; when on, emit
  greyed. Realise "suppress the stem group when all notes invisible" by the
  same all-invisible check MuseScore uses (`allElementsInvisible`).

- [ ] **Step 1: Extend the test**

Add to `InvisibleLayoutTests`:

```swift
    @Test func hiddenNoteTaggedInvisibleWhenToggleOn() {
        var note = Note(pitch: 60, tpc: 14)
        note.visible = false
        let chord = Chord(duration: .quarter, notes: [note])
        let score = TestScores.singleMeasure(extraVoiceElements: [.chord(chord)])
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(showsInvisibleElements: true),
            availableWidth: 800,
        )
        let chordNotes = doc.systems.flatMap(\.measures).flatMap(\.elements)
            .compactMap { el -> [LayoutChordNote]? in
                if case let .chord(notes, _, _, _, _, _, _, _, _) = el { notes }
                else { nil }
            }
            .flatMap { $0 }
        #expect(chordNotes.contains { $0.isInvisible })
    }

    @Test func hiddenNotePreservesSlotWhenToggleOff() {
        // Same single-note chord, visible vs hidden, must produce the same
        // chord stemOrigin.x (slot preserved — glyph suppression only).
        func chordX(hidden: Bool) -> CGFloat? {
            var note = Note(pitch: 60, tpc: 14)
            note.visible = !hidden
            let chord = Chord(duration: .quarter, notes: [note])
            let score = TestScores.singleMeasure(extraVoiceElements: [.chord(chord)])
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(showsInvisibleElements: false),
                availableWidth: 800,
            )
            for el in doc.systems.flatMap(\.measures).flatMap(\.elements) {
                if case let .chord(_, _, _, so, _, _, _, _, _) = el { return so.x }
            }
            return nil
        }
        #expect(chordX(hidden: false) == chordX(hidden: true))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter InvisibleLayoutTests`
Expected: `hiddenNoteTaggedInvisibleWhenToggleOn` FAILS (flag never set).

- [ ] **Step 3: Set `isInvisible` at chord-note construction**

In `LayoutEngine+Placement.swift` at the main chord-note construction
(~line 582) and the mirror-pass reconstruction (~line 1551), pass:

```swift
    isInvisible: !note.visible && ctx.options.showsInvisibleElements,
```

In the mirror pass (which copies an existing `LayoutChordNote n`), carry the
existing flag through:

```swift
    isInvisible: n.isInvisible,
```

- [ ] **Step 4: Suppress glyphs when toggle off + note hidden**

At the chord/rest emission site, when `showsInvisibleElements == false`:
- For a chord, drop noteheads whose `note.visible == false` from the emitted
  `LayoutChordNote` list **without** changing the chord's `stemOrigin`/slot.
- When the chord itself is hidden (`chord.visible == false`) or all notes
  are invisible, route the whole chord/rest `LayoutElement` to `invisibleOut`
  if the toggle is on, else suppress its glyphs (do not emit the
  notehead/stem/beam `LayoutElement`s) while still advancing the cursor/slot.

> This is the subtlest step. Implement incrementally and lean on the two new
> tests: `hiddenNotePreservesSlotWhenToggleOff` guards slot preservation;
> `hiddenNoteTaggedInvisibleWhenToggleOn` guards tagging. If the
> all-notes-invisible stem-suppression interacts badly with beaming, scope
> this task to per-note tagging + single-note suppression and split
> beam-group suppression into a follow-up commit — record the split.

- [ ] **Step 5: Run tests + full build**

Run: `swift test --filter InvisibleLayoutTests && swift build && swift test`
Expected: PASS; full suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift Tests/SheetMusicTests/InvisibleLayoutTests.swift
git commit -m "feat(layout): propagate note/chord visibility (slot preserved, per-notehead tagged)"
```

---

### Task 1.5: Per-notehead greying in both chord renderers

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift` (chord `case`, notehead draw)
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift` (chord `case`, notehead draw)

When drawing chord noteheads, a `LayoutChordNote` with `isInvisible == true`
is drawn at 50 % opacity (Canvas) / via a half-opacity colour (CALayer),
matching the container-level greying.

- [ ] **Step 1: Canvas — grey individual invisible noteheads**

In `ScoreCanvas.swift`, in the `case .chord(...)` block where each
`LayoutChordNote` notehead is drawn, wrap the per-note draw so that when
`note.isInvisible`, the notehead (and its accidental/dot/ledger) is drawn
through a `var grey = context; grey.opacity = 0.5` copy instead of the main
`context`. Quote the existing per-note loop and add the branch:

```swift
for note in notes {
    if note.isInvisible {
        var grey = context
        grey.opacity = 0.5
        drawNotehead(note, /* existing args */, into: &grey)
    } else {
        drawNotehead(note, /* existing args */, into: &context)
    }
}
```

(Match the real notehead-drawing call in the chord case; the principle is to
route invisible noteheads through the half-opacity context copy.)

- [ ] **Step 2: CALayer — grey individual invisible noteheads**

In `ScoreLayerBuilder+Element.swift`, in the chord `case`, when a
`LayoutChordNote.isInvisible`, set the notehead shape layer's `opacity` to
`0.5` (or build it into a half-opacity child layer). Mirror the Canvas
behaviour exactly (dual-renderer parity rule).

- [ ] **Step 3: Build + run**

Run: `swift build && swift test`
Expected: PASS — build clean; existing rendering tests unchanged (no notes
are invisible unless the toggle + hidden source combine).

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/ScoreCanvas.swift Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift
git commit -m "feat(ui): grey individual invisible noteheads in both renderers"
```

---

### Task 1.6: Extend the MIDI invariant test to dynamics + notes

**Files:**
- Modify: `Tests/SheetMusicTests/VisibilityMidiInvariantTests.swift`

- [ ] **Step 1: Add cases**

Add tests that flip `visible` on a `Dynamic` and on a `Note` and assert
byte-identical SMF (same pattern as Task 0.11). Reuse the same
fixture/render/encode helpers.

- [ ] **Step 2: Run + commit**

Run: `swift test --filter VisibilityMidiInvariantTests`
Expected: PASS.

```bash
git add Tests/SheetMusicTests/VisibilityMidiInvariantTests.swift
git commit -m "test(midi): extend visibility invariant to notes + dynamics"
```

---

### Phase 1 verification gate

- [ ] `swift build` + `swift test` green (incl. `MidiExportTests`).
- [ ] Android cross-build of Core + MSCX resolves.
- [ ] Manual (Mac app): a hidden note shows a gap (slot preserved) with the
      toggle off, and a grey notehead with it on.

Phase 1 is independently mergeable.

---

# Phase 2 — Structural: Clef, KeySignature, TimeSignature, BarLine

These have no `TextProperties`, so the encoder appends
`elementProperties.mscxChildren()` immediately before the closing
`return XMLTreeNode(...)`.

### Task 2.1: Model + MSCX round-trip for Clef, KeySignature, TimeSignature, BarLine

**Files:**
- Modify model: `Sources/SheetMusicCore/Score/Clef.swift`, `KeySignature.swift`, `TimeSignature.swift`, `BarLine.swift`
- Modify decoders: `MSCXDecoder+Clef.swift`, `+KeySignature.swift`, `+TimeSignature.swift`, `+BarLine.swift`
- Modify encoders: `MSCXEncoder+Clef.swift`, `+KeySignature.swift`, `+TimeSignature.swift`, `+BarLine.swift`
- Test: `Tests/SheetMusicTests/Phase2RoundTripTests.swift`

- [ ] **Step 1: Write the failing round-trip test**

Create `Tests/SheetMusicTests/Phase2RoundTripTests.swift` covering each
type: decode a node carrying `<visible>0</visible>`, assert
`visible == false`, re-encode, assert the tag is present; and assert a
default-visible value omits the tag. Example for `BarLine`:

```swift
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite struct Phase2RoundTripTests {
    @Test func barLineVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "BarLine",
            children: [XMLTreeNode(name: "visible", text: "0")],
        )
        let bar = try MSCXBarLineDecoder.decode(node)   // adapt name
        #expect(bar.visible == false)
        #expect(bar.encode().first("visible")?.text == "0")
    }

    @Test func barLineVisibleTrueOmitsTag() throws {
        #expect(BarLine(subtype: nil).encode().first("visible") == nil)
    }
    // … analogous cases for Clef, KeySignature, TimeSignature …
}
```

(Adapt decoder type names and the TimeSignature/KeySignature construction —
they require `<sigN>/<sigD>` and `<concertKey>`/`<accidental>` children
respectively; build valid nodes.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter Phase2RoundTripTests`
Expected: FAIL.

- [ ] **Step 3: Model edits (Recipe A)**

Add `elementProperties` + `visible` sugar + trailing `visible: Bool = true`
init param to each of `Clef`, `KeySignature`, `TimeSignature`, `BarLine`.

- [ ] **Step 4: Decoder edits (Recipe B)**

Each decoder currently returns the constructed value directly. Bind to a
`var`, assign
`x.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)`,
return. KeySignature has multiple early `return KeySignature(...)` branches —
apply the assignment to each branch, or refactor to compute the value once,
set `.elementProperties`, and return at the end.

- [ ] **Step 5: Encoder edits (Recipe B)**

Each encoder builds `children` (or returns inline). Insert
`children.append(contentsOf: elementProperties.mscxChildren())` before the
closing `return XMLTreeNode(...)`. For `TimeSignature`/`KeySignature`/`Clef`
which return inline `XMLTreeNode(... children: [...])`, refactor to a
`var children` accumulator first, then append the helper output, then
return.

- [ ] **Step 6: Run tests + full build**

Run: `swift test --filter Phase2RoundTripTests && swift build && swift test`
Expected: PASS; full suite green.

- [ ] **Step 7: Commit**

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicCore/Score/Clef.swift Sources/SheetMusicCore/Score/KeySignature.swift Sources/SheetMusicCore/Score/TimeSignature.swift Sources/SheetMusicCore/Score/BarLine.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Clef.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+KeySignature.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+TimeSignature.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+BarLine.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Clef.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+TimeSignature.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+BarLine.swift Tests/SheetMusicTests/Phase2RoundTripTests.swift
git commit -m "feat: round-trip visibility for Clef/KeySig/TimeSig/BarLine"
```

---

### Task 2.2: Honour structural-element visibility in layout

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`
  (clef / keySignature / timeSignature / barLine emission sites)
- Test: extend `Tests/SheetMusicTests/InvisibleLayoutTests.swift`

Structural elements reserve their slot (hiding a clef does not collapse
spacing). Apply Recipe C at each emission site: gate with
`guard x.visible || ctx.options.showsInvisibleElements else { break }`, build
the `LayoutElement`, route to `out` or `invisibleOut` by `x.visible`. The
spacing-affecting width reservation (clef/key/time widths) must stay
unconditional — only the *glyph emission* is routed.

- [ ] **Step 1: Extend the test**

Add a case: a measure whose `Clef.visible == false`; with the toggle on, the
`.clef` element appears in `invisibleElements`, not `elements`; with it off,
in neither; and the following note's x position is identical in both cases
(slot preserved).

- [ ] **Step 2: Run to verify failure, then implement Recipe C**

Run: `swift test --filter InvisibleLayoutTests` (new case fails) → implement
→ rerun.

- [ ] **Step 3: Full build + commit**

Run: `swift build && swift test`

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift Tests/SheetMusicTests/InvisibleLayoutTests.swift
git commit -m "feat(layout): honour Clef/KeySig/TimeSig/BarLine visibility (slot preserved)"
```

---

### Phase 2 verification gate

- [ ] `swift build` + `swift test` green.
- [ ] Android cross-build resolves.

Phase 2 is independently mergeable.

---

# Phase 3 — Remaining: Fermata, RehearsalMark, Lyric, Arpeggio

### Task 3.1: Model + MSCX round-trip for Fermata, RehearsalMark, Lyric

**Files:**
- Modify model: `Sources/SheetMusicCore/Score/Fermata.swift`, `RehearsalMark.swift`, `Lyric.swift`
- Modify decoders: `MSCXDecoder+RehearsalMark.swift`; Fermata is decoded inline in `MSCXDecoder+Voice.swift` (~line 211); Lyric is decoded inline in `MSCXDecoder+Chord.swift` (~lines 30–41)
- Modify encoders: `MSCXEncoder+Fermata.swift`, `+RehearsalMark.swift`, `+Lyric.swift`
- Test: `Tests/SheetMusicTests/Phase3RoundTripTests.swift`

- [ ] **Step 1: Write the failing round-trip test**

Cover Fermata, RehearsalMark, Lyric (decode `<visible>0</visible>` → assert
false → re-encode → assert tag present; default omits tag). For Fermata,
test the inline path through the voice decoder if no standalone decoder
exists, or test `Fermata.encode()` + a directly-built node for decode.

- [ ] **Step 2: Model edits (Recipe A)** for Fermata, RehearsalMark, Lyric.

- [ ] **Step 3: Decoder edits**

- `RehearsalMark`: Recipe B (bind `var`, assign aggregate, return).
- `Fermata` (inline in `MSCXDecoder+Voice.swift` ~211): the case builds
  `Fermata(subtype:timeStretch:)`. Add
  `var fermata = Fermata(...); fermata.elementProperties = ElementProperties(decodingMSCXChildrenOf: child); appendVoiceElement(.fermata(fermata))`.
- `Lyric` (inline in `MSCXDecoder+Chord.swift` ~30–41): after building the
  `Lyric(...)`, set its `.elementProperties` from the `lyricsNode`.

- [ ] **Step 4: Encoder edits (Recipe B)** for Fermata, RehearsalMark, Lyric
  (`children.append(contentsOf: elementProperties.mscxChildren())` before the
  closing `return`; for RehearsalMark/Lyric, before
  `properties.appendXML(to:)` / `props.appendXML(to:)`).

- [ ] **Step 5: Run tests + full build**

Run: `swift test --filter Phase3RoundTripTests && swift build && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicCore/Score/Fermata.swift Sources/SheetMusicCore/Score/RehearsalMark.swift Sources/SheetMusicCore/Score/Lyric.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+RehearsalMark.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Fermata.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+RehearsalMark.swift Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Lyric.swift Tests/SheetMusicTests/Phase3RoundTripTests.swift
git commit -m "feat: round-trip visibility for Fermata/RehearsalMark/Lyric"
```

---

### Task 3.2: Arpeggio visibility (model + layout only; encode deferred)

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Arpeggio.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift` (arpeggio decode ~17–23)
- Test: `Tests/SheetMusicTests/Phase3ArpeggioTests.swift`

> **Known gap:** `Arpeggio` is currently **not serialized** by the Chord
> encoder (the model field round-trips as a no-op on encode). So a full
> MSCX round-trip of `<Arpeggio><visible>0` cannot be asserted until arpeggio
> encoding exists. This task adds the model field + decode + layout honouring
> only, and documents the encode gap. Adding arpeggio serialization is out of
> scope (separate work).

- [ ] **Step 1: Write the test (decode + model only)**

```swift
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite struct Phase3ArpeggioTests {
    @Test func arpeggioDefaultsVisible() {
        #expect(Arpeggio(subtype: 0, timeStretch: 1, userLen1: 0).visible == true)
    }

    @Test func arpeggioDecodesVisibleFalse() throws {
        let chordNode = XMLTreeNode(
            name: "Chord",
            children: [
                XMLTreeNode(name: "durationType", text: "quarter"),
                XMLTreeNode(name: "Arpeggio", children: [
                    XMLTreeNode(name: "subtype", text: "0"),
                    XMLTreeNode(name: "visible", text: "0"),
                ]),
                XMLTreeNode(name: "Note", children: [
                    XMLTreeNode(name: "pitch", text: "60"),
                    XMLTreeNode(name: "tpc", text: "14"),
                ]),
            ],
        )
        let chord = try MSCXChordDecoder.decode(chordNode)   // adapt name
        #expect(chord.arpeggio?.visible == false)
    }
}
```

(Adapt the `Arpeggio` init and decoder names to the real ones.)

- [ ] **Step 2: Run to verify failure → implement → rerun**

- Recipe A on `Arpeggio` (`elementProperties` + `visible` sugar + init param).
- In `MSCXDecoder+Chord.swift` arpeggio block, after building `arpeggio`, set
  `arpeggio?.elementProperties = ElementProperties(decodingMSCXChildrenOf: arpeggioNode)`.

- [ ] **Step 3: Layout honouring**

In `LayoutEngine+Placement.swift`, where `.arpeggioWiggle` (and the chord's
`hasArpeggio`) is emitted, suppress / route the wiggle by `arpeggio.visible`
using Recipe C (toggle-off: no wiggle; toggle-on: wiggle into `invisibleOut`).

- [ ] **Step 4: Run + full build + commit**

Run: `swift test --filter Phase3ArpeggioTests && swift build && swift test`

```bash
Scripts/gate-android-tests.sh
git add Sources/SheetMusicCore/Score/Arpeggio.swift Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift Tests/SheetMusicTests/Phase3ArpeggioTests.swift
git commit -m "feat: Arpeggio visibility (model + decode + layout; encode deferred)"
```

---

### Phase 3 verification gate

- [ ] `swift build` + `swift test` green.
- [ ] Android cross-build resolves.
- [ ] `docs/superpowers/specs/2026-05-28-element-visibility-design.md` §8 "Out
      of scope" still accurately lists MusicXML `print-object` and the
      colour/offset consolidation as future work; add the Arpeggio-encode gap
      to the spec's risks/notes if not already captured.

---

## Final integration checklist (after all phases)

- [ ] `swift test` 100 % green including `MidiExportTests` (12 cases).
- [ ] `VisibilityMidiInvariantTests` proves SMF bytes unchanged by visibility.
- [ ] `swiftlint --quiet Sources Tests` — 0 warnings (watch the 300-line file
      cap; `LayoutEngine+Placement.swift` already carries
      `swiftlint:disable` for `function_body_length`).
- [ ] Android: `SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28`
      resolves (Core / MSCX / Layout are Android targets;
      `export TOOLCHAINS=org.swift.632202605101a` first).
- [ ] Both renderers grey invisible elements identically (dual-renderer
      parity) — visual check in `SheetMusicExampleMac`.
- [ ] PDF export never greys (always `showsInvisibleElements: false`).
