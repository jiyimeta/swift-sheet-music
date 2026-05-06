# Layout Break Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tri-state `LayoutBreakPolicy` to `ScoreViewOptions` (and to `PDFExporter.Options`) so callers can ignore the score's authored `<LayoutBreak>line` / `<LayoutBreak>page` markup at display / export time.

**Architecture:** Introduce a `Sendable & Equatable` enum with three cases (`.honor`, `.ignoreSystemBreaks`, `.ignoreAll`). Thread it as a parameter through the layout-wrap helpers (`measureForcesLineBreak`, `balancedMeasuresPerSystem`), the two `paginate` overloads (`PagedScoreView` and `PDFExporter`), and the `BreakIndicatorOverlay`. Defaults preserve current behavior at every call site.

**Tech Stack:** Swift 5.10+, Swift Testing (`@Test`, `#expect`), SwiftPM. Library targets touched: `SheetMusicLayout`, `SheetMusicUI`, `SheetMusicPDF`. Test target: `SheetMusicTests`.

---

## Spec reference

Source spec: `docs/superpowers/specs/2026-05-07-layout-break-policy-design.md`.

Semantic table (from the spec — re-verify any edit against this):

| policy | `<LayoutBreak>line` → system break | `<LayoutBreak>page` → system break | `<LayoutBreak>page` → page close |
| --- | --- | --- | --- |
| `.honor` | yes | yes | yes |
| `.ignoreSystemBreaks` | no | yes | yes |
| `.ignoreAll` | no | no | no |

## File map

Files touched (new + modified):

- **Modify** `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift` — add `LayoutBreakPolicy` enum and `breakPolicy` field.
- **Modify** `Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift` — make `measureForcesLineBreak` and `balancedMeasuresPerSystem` policy-aware.
- **Modify** `Sources/SheetMusicLayout/Layout/LayoutEngine+Packing.swift` — forward `context.options.breakPolicy` into the two helper calls.
- **Modify** `Sources/SheetMusicUI/PagedScoreView.swift` — `paginate(systems:pageHeight:policy:)`, propagate `options.breakPolicy` into `pageOpts`, pass it to `paginate`.
- **Modify** `Sources/SheetMusicUI/Rendering/BreakIndicatorOverlay.swift` — add `policy:` init parameter (default `.honor`), filter indicators by policy.
- **Modify** `Sources/SheetMusicUI/ScoreView.swift` — forward `options.breakPolicy` into the two `BreakIndicatorOverlay` call sites.
- **Modify** `Sources/SheetMusicPDF/PDFExporter.swift` — add `breakPolicy` to `PDFExporter.Options`, propagate to `layoutOptions`, pass to `paginate(systems:page:policy:)`, forward to `PDFPageView`.
- **Modify** `Sources/SheetMusicPDF/PDFPageView.swift` — add `policy:` init parameter (default `.honor`), pass it through to `BreakIndicatorOverlay`.
- **Modify** `Tests/SheetMusicTests/LayoutBreakTests.swift` — add policy-aware tests (cases 1, 2, 3 from spec).

No new test fixture is required; tests synthesize `Score` values inline (matching the existing tests in the file).

---

## Task 1: Add `LayoutBreakPolicy` enum and `ScoreViewOptions.breakPolicy`

**Files:**
- Modify: `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`
- Test: `Tests/SheetMusicTests/LayoutBreakTests.swift`

This task only adds the type + field. Threading through callers happens in Task 2+.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/LayoutBreakTests.swift`, inside the `LayoutBreakTests` suite:

```swift
/// `LayoutBreakPolicy` is `Sendable & Equatable`, has the three
/// designed cases, and `ScoreViewOptions` defaults `breakPolicy`
/// to `.honor` for source-compatibility.
@Test func breakPolicyDefault() {
    guard #available(macOS 15.0, iOS 16.0, *) else { return }
    let opts = ScoreViewOptions()
    #expect(opts.breakPolicy == .honor)
    let custom = ScoreViewOptions(breakPolicy: .ignoreAll)
    #expect(custom.breakPolicy == .ignoreAll)
    // All three cases distinct.
    let cases: [LayoutBreakPolicy] = [
        .honor, .ignoreSystemBreaks, .ignoreAll
    ]
    #expect(Set(cases.map { "\($0)" }).count == 3)
}
```

- [ ] **Step 2: Run the test to verify it fails to build**

Run: `swift test --filter LayoutBreakTests/breakPolicyDefault`
Expected: build error — `LayoutBreakPolicy` and `breakPolicy` don't exist yet.

- [ ] **Step 3: Add `LayoutBreakPolicy` and the `breakPolicy` field**

Replace the contents of `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift` with:

```swift
import CoreGraphics

/// Policy for honoring authored `<LayoutBreak>` markup at display time.
///
/// MuseScore stores explicit line / page breaks on each measure; this
/// enum lets callers selectively ignore them when wrapping a score
/// authored for a different page size or aggregating into a
/// continuous-flow reader. The score model is unchanged — only how
/// the layout / pagination / overlay code consumes the flags.
///
/// | policy                | line→system | page→system | page→page-close |
/// | `.honor`              | yes         | yes         | yes             |
/// | `.ignoreSystemBreaks` | no          | yes         | yes             |
/// | `.ignoreAll`          | no          | no          | no              |
@available(macOS 15.0, iOS 16.0, *)
public enum LayoutBreakPolicy: Sendable, Equatable {
    /// Default — `<LayoutBreak>line` and `<LayoutBreak>page` both
    /// force a new system; `<LayoutBreak>page` additionally closes
    /// the current page. Equivalent to behavior prior to this option.
    case honor

    /// Ignore `<LayoutBreak>line`. `<LayoutBreak>page` still forces
    /// both a system break and a page close (a page break implies a
    /// system break in MuseScore's model — see
    /// `engraving/rendering/score/systemlayout.cpp:262`).
    case ignoreSystemBreaks

    /// Ignore both `<LayoutBreak>line` and `<LayoutBreak>page`. The
    /// engine wraps purely on available width; the paginator only
    /// closes pages on vertical overflow.
    case ignoreAll
}

/// Tunable knobs for `ScoreView`. v1 intentionally keeps this small —
/// layout is driven by the view's available width and these values.
@available(macOS 15.0, iOS 16.0, *)
public struct ScoreViewOptions: Sendable, Equatable {
    /// Height of one five-line staff in points. Defaults to 28 pt
    /// (roughly rastral 3).
    public var staffSize: CGFloat
    /// Vertical gap between systems (lines of music) in points.
    public var systemGap: CGFloat
    /// When true, measures wrap to the view's available width.
    /// When false, the layout emits a single long system and the caller is
    /// expected to wrap the `ScoreView` in a `ScrollView(.horizontal)`.
    public var wrapToViewWidth: Bool
    /// When true, the layout reserves space for `Score.titleFrame`
    /// (a `<VBox>` in MuseScore) above the first system and the
    /// renderer paints title / subtitle / composer text inside it.
    /// Off by default for the horizontal scroll layout, where a
    /// page-style title block doesn't fit the editing flow.
    public var includeTitleFrame: Bool
    /// How to consume authored `<LayoutBreak>` markup. Default
    /// `.honor` reproduces behavior from before this option existed.
    public var breakPolicy: LayoutBreakPolicy

    public init(
        staffSize: CGFloat = 28,
        systemGap: CGFloat = 40,
        wrapToViewWidth: Bool = true,
        includeTitleFrame: Bool = true,
        breakPolicy: LayoutBreakPolicy = .honor
    ) {
        self.staffSize = staffSize
        self.systemGap = systemGap
        self.wrapToViewWidth = wrapToViewWidth
        self.includeTitleFrame = includeTitleFrame
        self.breakPolicy = breakPolicy
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter LayoutBreakTests/breakPolicyDefault`
Expected: PASS.

- [ ] **Step 5: Run the full layout suite to confirm nothing else regressed**

Run: `swift test --filter LayoutBreakTests`
Expected: every existing test in the suite still passes (default `.honor` is source-compatible).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Options/ScoreViewOptions.swift \
        Tests/SheetMusicTests/LayoutBreakTests.swift
git commit -m "feat(layout): add LayoutBreakPolicy on ScoreViewOptions"
```

---

## Task 2: Make `measureForcesLineBreak` and `balancedMeasuresPerSystem` policy-aware

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Packing.swift`
- Test: `Tests/SheetMusicTests/LayoutBreakTests.swift`

The existing test `helperReadsStaffZero` calls `measureForcesLineBreak(at:staves:)` (no policy arg) — it must keep working. We add the `policy:` argument and update `LayoutBreakTests.helperReadsStaffZero` to pass `.honor` explicitly. Then we add policy-variant tests.

- [ ] **Step 1: Write the failing tests**

Append the following two tests to `LayoutBreakTests.swift`. The first asserts policy-aware semantics on the helper; the second asserts integrated behavior in `LayoutEngine.layout`:

```swift
/// `measureForcesLineBreak` honours `LayoutBreakPolicy`:
/// `.honor` keeps the existing line-or-page logic;
/// `.ignoreSystemBreaks` only respects page breaks;
/// `.ignoreAll` returns false unconditionally.
@Test func helperHonoursPolicy() {
    guard #available(macOS 15.0, iOS 16.0, *) else { return }
    let mLine = Measure(voices: [], lineBreak: true)
    let mPage = Measure(voices: [], pageBreak: true)
    let mPlain = Measure(voices: [])
    let staves = [Staff(measures: [mLine, mPage, mPlain])]

    // .honor — line and page both force.
    #expect(LayoutEngine.measureForcesLineBreak(
        at: 0, staves: staves, policy: .honor) == true)
    #expect(LayoutEngine.measureForcesLineBreak(
        at: 1, staves: staves, policy: .honor) == true)
    // .ignoreSystemBreaks — line ignored, page still forces.
    #expect(LayoutEngine.measureForcesLineBreak(
        at: 0, staves: staves, policy: .ignoreSystemBreaks) == false)
    #expect(LayoutEngine.measureForcesLineBreak(
        at: 1, staves: staves, policy: .ignoreSystemBreaks) == true)
    // .ignoreAll — neither forces.
    #expect(LayoutEngine.measureForcesLineBreak(
        at: 0, staves: staves, policy: .ignoreAll) == false)
    #expect(LayoutEngine.measureForcesLineBreak(
        at: 1, staves: staves, policy: .ignoreAll) == false)
    // Plain measure: false under every policy.
    for p: LayoutBreakPolicy in [.honor, .ignoreSystemBreaks, .ignoreAll] {
        #expect(LayoutEngine.measureForcesLineBreak(
            at: 2, staves: staves, policy: p) == false)
    }
}

/// `.ignoreAll` collapses authored line breaks: the same fixture
/// that produces three systems under `.honor` produces a single
/// system when the policy ignores breaks. Mirrors spec test case 1.
@Test func ignoreAllCollapsesAuthoredLineBreaks() {
    guard #available(macOS 15.0, iOS 16.0, *) else { return }
    let chord = Chord(
        duration: .quarter,
        notes: [Note(pitch: 60, tpc: 14)]
    )
    // Six measures with a forced line break on indices 1 and 3 —
    // identical fixture to `layoutBreakForcesSystemSplit`.
    let measures = (0 ..< 6).map { idx in
        Measure(
            voices: [Voice(elements: [
                .chord(chord), .chord(chord),
                .chord(chord), .chord(chord),
            ])],
            lineBreak: idx == 1 || idx == 3
        )
    }
    let staff = Staff(measures: measures)
    let part = Part(
        id: "P1",
        instrument: Instrument(
            id: "i",
            articulations: [InstrumentArticulation()]
        ),
        staves: [staff]
    )
    let score = Score(division: 480, parts: [part])
    let opts = ScoreViewOptions(
        staffSize: 16, systemGap: 16,
        wrapToViewWidth: true,
        breakPolicy: .ignoreAll
    )
    // Wide enough that no width-driven wrap fires either.
    let doc = LayoutEngine.layout(
        score: score, options: opts, availableWidth: 4000
    )
    #expect(doc.systems.count == 1)
    #expect(doc.systems.first?.measures.count == 6)
}

/// `.ignoreSystemBreaks` keeps `<LayoutBreak>page`-implied system
/// breaks. Mirrors spec test case 2.
@Test func ignoreSystemBreaksKeepsPageImpliedSystemBreaks() {
    guard #available(macOS 15.0, iOS 16.0, *) else { return }
    let chord = Chord(
        duration: .quarter,
        notes: [Note(pitch: 60, tpc: 14)]
    )
    // Six measures, page break on measure 2 (index 2).
    let measures = (0 ..< 6).map { idx in
        Measure(
            voices: [Voice(elements: [
                .chord(chord), .chord(chord),
                .chord(chord), .chord(chord),
            ])],
            pageBreak: idx == 2
        )
    }
    let staff = Staff(measures: measures)
    let part = Part(
        id: "P1",
        instrument: Instrument(
            id: "i",
            articulations: [InstrumentArticulation()]
        ),
        staves: [staff]
    )
    let score = Score(division: 480, parts: [part])
    let opts = ScoreViewOptions(
        staffSize: 16, systemGap: 16,
        wrapToViewWidth: true,
        breakPolicy: .ignoreSystemBreaks
    )
    let doc = LayoutEngine.layout(
        score: score, options: opts, availableWidth: 4000
    )
    // Page break on measure 2 → still forces a system break,
    // even under .ignoreSystemBreaks. Two systems: 3 + 3.
    #expect(doc.systems.count == 2)
    #expect(doc.systems[0].measures.count == 3)
    #expect(doc.systems[1].measures.count == 3)
}
```

Update the existing `helperReadsStaffZero` test to pass `policy: .honor` to the helper (the new required parameter) — replace its four `measureForcesLineBreak` calls with the policy-passing form:

```swift
#expect(LayoutEngine.measureForcesLineBreak(
    at: 0, staves: staves, policy: .honor
) == true)
#expect(
    LayoutEngine.measureForcesLineBreak(
        at: 1, staves: staves, policy: .honor
    ) == true,
    "page break should also force a system break"
)
#expect(LayoutEngine.measureForcesLineBreak(
    at: 2, staves: staves, policy: .honor
) == false)
// Out-of-range index returns false rather than crashing.
#expect(LayoutEngine.measureForcesLineBreak(
    at: 99, staves: staves, policy: .honor
) == false)
```

- [ ] **Step 2: Run tests to verify failures**

Run: `swift test --filter LayoutBreakTests`
Expected: build error — `measureForcesLineBreak` does not accept a `policy:` argument; `helperHonoursPolicy`, `ignoreAllCollapsesAuthoredLineBreaks`, and `ignoreSystemBreaksKeepsPageImpliedSystemBreaks` cannot resolve symbols.

- [ ] **Step 3: Update `measureForcesLineBreak` and `balancedMeasuresPerSystem`**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift`, replace the `measureForcesLineBreak` static and the `balancedMeasuresPerSystem` static with policy-aware versions:

```swift
/// True when the measure at `idx` should force the next measure
/// onto a new system, given `policy`. Looks only at staff 0 — line
/// / page breaks are a document-level engraving decision, not
/// per-staff (MuseScore stores them on `MeasureBase`, which is
/// shared across staves). Mirrors
/// `engraving/dom/measurebase.h::lineBreak()` plus the page-break
/// promotion in `engraving/rendering/score/systemlayout.cpp:262`
/// (a page break implies a system break) — promotion is gated on
/// `policy` per `LayoutBreakPolicy`.
static func measureForcesLineBreak(
    at idx: Int, staves: [Staff], policy: LayoutBreakPolicy
) -> Bool {
    guard let s0 = staves.first,
          idx < s0.measures.count else { return false }
    let m = s0.measures[idx]
    switch policy {
    case .honor:              return m.lineBreak || m.pageBreak
    case .ignoreSystemBreaks: return m.pageBreak
    case .ignoreAll:          return false
    }
}
```

In the same file, change `balancedMeasuresPerSystem`'s signature and call to `measureForcesLineBreak`. Add `policy: LayoutBreakPolicy` as the last parameter (no default — it's an internal helper, callers must be explicit):

```swift
static func balancedMeasuresPerSystem(
    fromIndex startIdx: Int,
    measureCount: Int,
    minWidths: [CGFloat],
    firstHeaderBoost: CGFloat,
    contentAvail: CGFloat,
    staves: [Staff],
    policy: LayoutBreakPolicy
) -> Int {
    // Find the END of the current break-bounded span.
    var endIdx = measureCount
    for i in startIdx ..< measureCount
        where measureForcesLineBreak(
            at: i, staves: staves, policy: policy
        )
    {
        endIdx = i + 1
        break
    }
    let span = endIdx - startIdx
    guard span > 0 else { return Int.max }
    if span > balancedSpanLimit { return Int.max }

    for numSystems in 1 ... span {
        let chunk = (span + numSystems - 1) / numSystems
        var maxChunkWidth: CGFloat = 0
        var i = startIdx
        while i < endIdx {
            let upper = min(i + chunk, endIdx)
            let slice = minWidths[i ..< upper]
            var w: CGFloat = slice.reduce(0, +)
            if i == startIdx { w += firstHeaderBoost }
            maxChunkWidth = max(maxChunkWidth, w)
            i = upper
        }
        if maxChunkWidth <= contentAvail {
            return chunk
        }
    }
    return 1
}
```

- [ ] **Step 4: Forward `breakPolicy` from `packSystems`**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Packing.swift`, update the two call sites to forward `context.options.breakPolicy`:

At the `balancedMeasuresPerSystem(...)` call (currently around lines 161–168), add `policy:` as the last argument:

```swift
let balancedTarget = context.options.wrapToViewWidth
    ? balancedMeasuresPerSystem(
        fromIndex: systemStart,
        measureCount: measureCount,
        minWidths: minWidths,
        firstHeaderBoost: firstHeaderBoost,
        contentAvail: contentAvail,
        staves: staves,
        policy: context.options.breakPolicy
    )
    : Int.max
```

At the `measureForcesLineBreak(...)` call inside the inner packing loop (currently around lines 226–234), pass the policy:

```swift
if context.options.wrapToViewWidth,
   cursor > systemStart,
   measureForcesLineBreak(
       at: cursor - 1,
       staves: staves,
       policy: context.options.breakPolicy
   )
{
    break
}
```

- [ ] **Step 5: Run the layout-break tests to verify they pass**

Run: `swift test --filter LayoutBreakTests`
Expected: all tests in the suite pass — `parsesLineBreak`, `parsesPageBreak`, `helperReadsStaffZero`, `helperHonoursPolicy`, `balancedWrapBetweenBreaks`, `horizontalModeIgnoresLineBreaks`, `layoutBreakForcesSystemSplit`, `breakPolicyDefault`, `ignoreAllCollapsesAuthoredLineBreaks`, `ignoreSystemBreaksKeepsPageImpliedSystemBreaks`.

- [ ] **Step 6: Run the full layout suite to confirm no upstream regression**

Run: `swift test --filter Layout`
Expected: every layout-related suite still passes (`LayoutBracketTests`, `LayoutCacheTests`, `LayoutEngineTests`, `LayoutPartLabelClefTests`, `LayoutSystemEventColumnsTests`).

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Packing.swift \
        Tests/SheetMusicTests/LayoutBreakTests.swift
git commit -m "feat(layout): apply LayoutBreakPolicy in wrap helpers"
```

---

## Task 3: Make `PagedScoreView.paginate` policy-aware

**Files:**
- Modify: `Sources/SheetMusicUI/PagedScoreView.swift`
- Test: `Tests/SheetMusicTests/LayoutBreakTests.swift`

`PagedScoreView.paginate` is `static func paginate(systems:pageHeight:)`, accessible from the test target via `@testable import SheetMusicUI`.

- [ ] **Step 1: Write the failing pagination test**

Append to `LayoutBreakTests.swift`:

```swift
/// `PagedScoreView.paginate` honours `<LayoutBreak>page` under
/// `.honor` (closing the page early) and ignores it under
/// `.ignoreAll` (only vertical overflow closes pages).
/// Mirrors spec test case 3.
@Test func paginateHonoursPolicy() {
    guard #available(macOS 15.0, iOS 16.0, *) else { return }
    // Three lightweight systems, each 100 pt tall. Page height
    // 1000 pt easily fits them all on one page — only a
    // pageBreak flag should split them.
    func makeSystem(pageBreak: Bool) -> LayoutSystem {
        let m = LayoutMeasure(
            measureIndex: 0,
            origin: .zero,
            width: 100,
            elements: [],
            pageBreak: pageBreak
        )
        return LayoutSystem(
            origin: .zero,
            size: CGSize(width: 100, height: 100),
            measures: [m],
            staffOrigins: [],
            partLabels: [],
            spanners: [],
            sp: 7
        )
    }
    let systems = [
        makeSystem(pageBreak: false),
        makeSystem(pageBreak: true),  // forces page close
        makeSystem(pageBreak: false),
    ]

    let honor = PagedScoreView.paginate(
        systems: systems, pageHeight: 1000, policy: .honor
    )
    #expect(honor.count == 2,
            "page break on system 1 should close page after it")
    #expect(honor[0].count == 2)
    #expect(honor[1].count == 1)

    let ignoreSysBreaks = PagedScoreView.paginate(
        systems: systems, pageHeight: 1000,
        policy: .ignoreSystemBreaks
    )
    #expect(ignoreSysBreaks.count == 2,
            ".ignoreSystemBreaks still closes pages on pageBreak")

    let ignoreAll = PagedScoreView.paginate(
        systems: systems, pageHeight: 1000, policy: .ignoreAll
    )
    #expect(ignoreAll.count == 1,
            ".ignoreAll lets all systems share one page")
    #expect(ignoreAll[0].count == 3)
}
```

> Reference: `LayoutMeasure.init` is at `Sources/SheetMusicLayout/Layout/LayoutMeasure.swift:29` (`measureIndex`, `origin`, `width`, `elements`, optional `markers`, `jumps`, `lineBreak`, `pageBreak`). `LayoutSystem.init` is at `Sources/SheetMusicLayout/Layout/LayoutSystem.swift:42` (`origin`, `size`, `measures`, `staffOrigins`, optional `staffAddresses`, `partLabels`, optional `brackets`, `spanners`, `sp`). The semantic constraints the test depends on: each measure carries a `pageBreak` flag, each system has a `size.height` that fits multiple-per-page, and `system.measures.last?.pageBreak` is true exactly when the synthesized flag is true.

- [ ] **Step 2: Run the test to verify it fails to build**

Run: `swift test --filter LayoutBreakTests/paginateHonoursPolicy`
Expected: build error — `PagedScoreView.paginate` does not accept a `policy:` argument.

- [ ] **Step 3: Add `policy:` to `paginate` and gate the page-close branch**

In `Sources/SheetMusicUI/PagedScoreView.swift`, update `paginate` (currently `static func paginate(systems:pageHeight:)`) to:

```swift
static func paginate(
    systems: [LayoutSystem],
    pageHeight: CGFloat,
    policy: LayoutBreakPolicy = .honor
) -> [[LayoutSystem]] {
    guard !systems.isEmpty, pageHeight > 0 else { return [] }
    var pages: [[LayoutSystem]] = []
    var current: [LayoutSystem] = []
    var usedHeight: CGFloat = 0

    for system in systems {
        let h = system.size.height
        if !current.isEmpty && usedHeight + h > pageHeight {
            pages.append(current)
            current = []
            usedHeight = 0
        }
        current.append(system)
        usedHeight += h
        // `<LayoutBreak>page` on the last measure of this system
        // closes the page immediately under `.honor` /
        // `.ignoreSystemBreaks`. `.ignoreAll` lets the page keep
        // packing until vertical overflow.
        if policy != .ignoreAll,
           system.measures.last?.pageBreak == true
        {
            pages.append(current)
            current = []
            usedHeight = 0
        }
    }
    if !current.isEmpty {
        pages.append(current)
    }
    return pages
}
```

- [ ] **Step 4: Forward `breakPolicy` from `pageContent` into `pageOpts` and `paginate`**

In the same file, update `pageContent(in:)` so the layout pass receives the caller's policy AND the paginator does too:

```swift
let pageOpts = ScoreViewOptions(
    staffSize: options.staffSize,
    systemGap: options.systemGap,
    wrapToViewWidth: true,
    breakPolicy: options.breakPolicy
)
let doc = LayoutEngine.layout(
    score: score, options: pageOpts,
    availableWidth: w
)
let pages = Self.paginate(
    systems: doc.systems,
    pageHeight: proxy.size.height,
    policy: options.breakPolicy
)
```

- [ ] **Step 5: Run the new test to verify it passes**

Run: `swift test --filter LayoutBreakTests/paginateHonoursPolicy`
Expected: PASS.

- [ ] **Step 6: Run the full test suite as a regression check**

Run: `swift test`
Expected: every test passes (default `.honor` keeps the existing 48-test baseline green).

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicUI/PagedScoreView.swift \
        Tests/SheetMusicTests/LayoutBreakTests.swift
git commit -m "feat(layout): apply LayoutBreakPolicy in paged pagination"
```

---

## Task 4: Add `breakPolicy` to `PDFExporter.Options` and thread through `paginate` / `PDFPageView`

**Files:**
- Modify: `Sources/SheetMusicPDF/PDFExporter.swift`
- Modify: `Sources/SheetMusicPDF/PDFPageView.swift`

The spec says PDF export should also respect the policy ("manual PDF render of a scored fixture under each policy"). Add `breakPolicy` to `PDFExporter.Options`, propagate to the internal `ScoreViewOptions`, pass to `paginate`, and forward to `PDFPageView` so the on-screen preview overlay matches.

No dedicated unit test is added for the PDF paginator — `PagedScoreView.paginate` already covers the policy logic at unit-test level, and `PDFExporterPageLayoutTests` covers the default-policy regression baseline.

- [ ] **Step 1: Add `breakPolicy` to `PDFExporter.Options`**

In `Sources/SheetMusicPDF/PDFExporter.swift`, update `Options`:

```swift
public struct Options: Sendable {
    public enum PageGeometry: Sendable {
        case fromScore
        case explicit(EngravingPage)
    }

    public enum StaffSize: Sendable {
        case fromScore
        case explicit(CGFloat)
    }

    public var page: PageGeometry
    public var staffSize: StaffSize
    public var systemGap: CGFloat
    public var title: String?
    public var author: String?
    /// How to consume authored `<LayoutBreak>` markup. Default
    /// `.honor` reproduces export behavior from before this option
    /// existed.
    public var breakPolicy: LayoutBreakPolicy

    public init(
        page: PageGeometry = .fromScore,
        staffSize: StaffSize = .fromScore,
        systemGap: CGFloat = 16,
        title: String? = nil,
        author: String? = nil,
        breakPolicy: LayoutBreakPolicy = .honor
    ) {
        self.page = page
        self.staffSize = staffSize
        self.systemGap = systemGap
        self.title = title
        self.author = author
        self.breakPolicy = breakPolicy
    }
}
```

- [ ] **Step 2: Forward `breakPolicy` into `layoutOptions` and `paginate`**

In `PDFExporter.export(score:options:)`, update the `layoutOptions` constructor (currently lines ~90–94) and the `paginate` call (currently line ~105):

```swift
let layoutOptions = ScoreViewOptions(
    staffSize: resolved.staffSize,
    systemGap: options.systemGap,
    wrapToViewWidth: true,
    breakPolicy: options.breakPolicy
)
```

```swift
let pages = paginate(
    systems: document.systems,
    page: resolved.page,
    policy: options.breakPolicy
)
```

- [ ] **Step 3: Make `PDFExporter.paginate` policy-aware**

Replace the public `paginate(systems:page:)` static with a policy-aware version. The change has two parts: (a) the function signature gains a defaulted `policy:` argument, and (b) the two `systemEndsPage` checks are gated on `policy != .ignoreAll`.

```swift
public static func paginate(
    systems: [LayoutSystem],
    page: EngravingPage,
    policy: LayoutBreakPolicy = .honor
) -> [PageBatch] {
    var pages: [PageBatch] = []
    var currentSystems: [LayoutSystem] = []
    var currentStartY: CGFloat = 0

    func usableHeight(forPageIndex idx: Int) -> CGFloat {
        let m = page.margins(forPageIndex: idx)
        return max(1, page.size.height - m.top - m.bottom)
    }

    func systemEndsPage(_ system: LayoutSystem) -> Bool {
        guard policy != .ignoreAll else { return false }
        return system.measures.last?.pageBreak ?? false
    }

    for system in systems {
        if currentSystems.isEmpty {
            currentStartY = pages.isEmpty ? 0 : system.origin.y
            currentSystems.append(system)
            if systemEndsPage(system) {
                pages.append(PageBatch(
                    startY: currentStartY,
                    systems: currentSystems
                ))
                currentSystems = []
            }
            continue
        }
        let bottomOnPage =
            (system.origin.y + system.size.height) - currentStartY
        if bottomOnPage > usableHeight(forPageIndex: pages.count) {
            pages.append(PageBatch(
                startY: currentStartY,
                systems: currentSystems
            ))
            currentStartY = system.origin.y
            currentSystems = [system]
        } else {
            currentSystems.append(system)
        }
        if systemEndsPage(system) && !currentSystems.isEmpty {
            pages.append(PageBatch(
                startY: currentStartY,
                systems: currentSystems
            ))
            currentSystems = []
        }
    }
    if !currentSystems.isEmpty {
        pages.append(PageBatch(
            startY: currentStartY,
            systems: currentSystems
        ))
    }
    return pages
}
```

- [ ] **Step 4: Forward `breakPolicy` into the per-page `PDFPageView` constructor**

In `PDFExporter.export`, the per-page `PDFPageView` constructor (currently lines ~122–132) gains a `policy:` argument so the on-screen preview overlay matches the export's policy:

```swift
let view = PDFPageView(
    systems: page.systems,
    pageStartY: page.startY,
    titleFrame: idx == 0 ? document.titleFrame : nil,
    metrics: document.metrics,
    pageSize: resolved.page.size,
    margins: margins,
    showBreakIndicators: false,
    policy: options.breakPolicy
)
```

- [ ] **Step 5: Add `policy:` parameter to `PDFPageView`**

In `Sources/SheetMusicPDF/PDFPageView.swift`, add a `policy: LayoutBreakPolicy` stored property (default `.honor`) and pass it to the `BreakIndicatorOverlay`:

```swift
let policy: LayoutBreakPolicy

public init(
    systems: [LayoutSystem],
    pageStartY: CGFloat,
    titleFrame: LayoutTitleFrame? = nil,
    metrics: StaffMetrics,
    pageSize: CGSize,
    margins: PageMargins,
    renderScale: CGFloat = 1,
    showBreakIndicators: Bool = false,
    policy: LayoutBreakPolicy = .honor
) {
    self.systems = systems
    self.pageStartY = pageStartY
    self.titleFrame = titleFrame
    self.metrics = metrics
    self.pageSize = pageSize
    self.margins = margins
    self.renderScale = renderScale
    self.showBreakIndicators = showBreakIndicators
    self.policy = policy
}
```

Update the `BreakIndicatorOverlay` invocation in `body` (currently line ~101) to forward the policy:

```swift
if showBreakIndicators {
    BreakIndicatorOverlay(
        mode: .document(
            systems: systems,
            documentYOffset: pageStartY - margins.top,
            xOffset: margins.leading
        ),
        metrics: metrics,
        policy: policy
    )
    .scaleEffect(renderScale, anchor: .topLeading)
}
```

> **Note:** This step references `BreakIndicatorOverlay`'s yet-unwritten `policy:` parameter. The compiler will reject this until Task 5 lands. Build / test verification for Task 4 is therefore deferred to Task 5's verification step. Do not commit Task 4 in isolation — Tasks 4 and 5 land together.

- [ ] **Step 6: Defer build / test until Task 5**

Skip running tests at the end of Task 4. The `BreakIndicatorOverlay(policy:)` call added above does not yet compile; Task 5 introduces the parameter. Move directly to Task 5 without committing.

---

## Task 5: Make `BreakIndicatorOverlay` policy-aware and update all call sites

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/BreakIndicatorOverlay.swift`
- Modify: `Sources/SheetMusicUI/PagedScoreView.swift`
- Modify: `Sources/SheetMusicUI/ScoreView.swift`

`BreakIndicatorOverlay` exists to visualize what the layout is honoring. When the policy ignores a break kind, showing its indicator is misleading — so the overlay filters its `indicators` list by policy.

- [ ] **Step 1: Add `policy:` parameter and filter indicators**

In `Sources/SheetMusicUI/Rendering/BreakIndicatorOverlay.swift`, replace the public `init` and `breakKind(for:)` to accept policy:

```swift
public let mode: Mode
public let metrics: StaffMetrics
public let policy: LayoutBreakPolicy

public init(
    mode: Mode,
    metrics: StaffMetrics,
    policy: LayoutBreakPolicy = .honor
) {
    self.mode = mode
    self.metrics = metrics
    self.policy = policy
}
```

```swift
private func breakKind(for m: LayoutMeasure) -> BreakKind? {
    switch policy {
    case .honor:
        if m.pageBreak { return .page }
        if m.lineBreak { return .line }
        return nil
    case .ignoreSystemBreaks:
        // Page indicators only — line breaks are ignored at
        // layout time, so showing their badges would mislead.
        if m.pageBreak { return .page }
        return nil
    case .ignoreAll:
        return nil
    }
}
```

> The existing `indicators` computed property iterates measures and consults `breakKind(for:)` per measure. Since `breakKind` now returns nil for filtered cases, `indicators` will be empty under `.ignoreAll` (matching the spec's "overlay shows nothing"). No change to `indicators` or `body` is required.

- [ ] **Step 2: Forward policy from the four call sites**

`Sources/SheetMusicUI/PagedScoreView.swift` — the per-system overlay inside `pageContent(in:)` (currently line ~98):

```swift
BreakIndicatorOverlay(
    mode: .system(system: sys),
    metrics: doc.metrics,
    policy: options.breakPolicy
)
```

`Sources/SheetMusicUI/ScoreView.swift` — vertical mode overlay (currently line ~148):

```swift
.overlay(alignment: .topLeading) {
    BreakIndicatorOverlay(
        mode: .system(system: sys),
        metrics: doc.metrics,
        policy: options.breakPolicy
    )
}
```

`Sources/SheetMusicUI/ScoreView.swift` — horizontal mode overlay (currently line ~198):

```swift
.overlay(alignment: .topLeading) {
    BreakIndicatorOverlay(
        mode: .system(system: system),
        metrics: doc.metrics,
        policy: options.breakPolicy
    )
}
```

`Sources/SheetMusicPDF/PDFPageView.swift` — already updated in Task 4.

- [ ] **Step 3: Build the package**

Run: `swift build`
Expected: clean build (no compiler errors). Both Task 4 and Task 5 should now compile together.

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: every test passes (target: 51 tests after this plan adds 5 new ones to `LayoutBreakTests`; original baseline is 48).

- [ ] **Step 5: Lint**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings, 0 errors.

If `swiftlint` is not installed locally, skip this step (it is documented as optional in `CLAUDE.md`).

- [ ] **Step 6: Commit (Tasks 4 + 5 together)**

```bash
git add Sources/SheetMusicPDF/PDFExporter.swift \
        Sources/SheetMusicPDF/PDFPageView.swift \
        Sources/SheetMusicUI/Rendering/BreakIndicatorOverlay.swift \
        Sources/SheetMusicUI/PagedScoreView.swift \
        Sources/SheetMusicUI/ScoreView.swift
git commit -m "feat(layout): apply LayoutBreakPolicy in PDF, indicator overlay, and views"
```

---

## Task 6: Final verification

**Files:** none (verification-only).

- [ ] **Step 1: Full build + test**

Run: `swift build && swift test`
Expected: clean build, all tests pass.

- [ ] **Step 2: Confirm test count grew by 5**

Five new tests added to `LayoutBreakTests` across Tasks 1–3:
- `breakPolicyDefault`
- `helperHonoursPolicy`
- `ignoreAllCollapsesAuthoredLineBreaks`
- `ignoreSystemBreaksKeepsPageImpliedSystemBreaks`
- `paginateHonoursPolicy`

Run: `swift test --filter LayoutBreakTests 2>&1 | grep -E "passed|failed"`
Expected: every test in the suite reports `passed`.

- [ ] **Step 3: Final commit log review**

Expected commits, in order:
1. `feat(layout): add LayoutBreakPolicy on ScoreViewOptions`
2. `feat(layout): apply LayoutBreakPolicy in wrap helpers`
3. `feat(layout): apply LayoutBreakPolicy in paged pagination`
4. `feat(layout): apply LayoutBreakPolicy in PDF, indicator overlay, and views`

Run: `git log --oneline main..HEAD`
Expected: the four commits above.

---

## Notes for the implementer

- **Default `.honor` everywhere.** Every defaulted parameter on a public surface (`ScoreViewOptions.init`, `PDFExporter.Options.init`, `PagedScoreView.paginate`, `PDFExporter.paginate`, `BreakIndicatorOverlay.init`, `PDFPageView.init`) defaults to `.honor`. This is what keeps the migration source-compatible.
- **Internal helpers do NOT default the policy.** `measureForcesLineBreak` and `balancedMeasuresPerSystem` take `policy:` as a required argument — every call site must be explicit so the policy doesn't silently fall back to `.honor` mid-pipeline. The two callers in `LayoutEngine+Packing.swift` both forward `context.options.breakPolicy`.
- **`.ignoreSystemBreaks` keeps page→system promotion.** This is the easy spot to get wrong. Reference: the `measureForcesLineBreak` switch returns `m.pageBreak` for `.ignoreSystemBreaks` (not `false`). The `breakKind(for:)` filter in `BreakIndicatorOverlay` mirrors this: page indicators show, line indicators don't.
- **No model changes.** `Measure.lineBreak` / `Measure.pageBreak` and the MSCX read path are unchanged.
- **PDFExporter.Options gains `breakPolicy`.** The spec says `PDFExporter.swift:105 — pass options.breakPolicy`, which implies the option exists on the exporter as well as on `ScoreViewOptions`. This plan makes that explicit (Task 4 step 1).
- **Tasks 4 + 5 land in one commit.** Task 4 introduces a call to `BreakIndicatorOverlay(policy:)` that doesn't compile until Task 5 lands. Verification and commit happen at the end of Task 5.

