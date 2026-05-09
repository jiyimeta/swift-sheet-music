# Multi-Measure Rest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a layout-time option that collapses consecutive rest
measures into a single multi-measure-rest bar (H-bar + count) without
touching the `Score` model or MIDI output.

**Architecture:** A new pure planner (`MultiMeasureRestPlanner`)
produces a `MultiMeasureRestPlan` (sorted, non-overlapping
`Range<Int>` runs of measure indices). The plan threads through
`LayoutEngine.RenderContext`. `packSystems` reads it to assign a
fixed collapsed width to run-start measures and width 0 to
run-interior measures. `buildSystem` skips interior indices and
emits a single `LayoutMeasure` for each run-start, carrying a new
`multiMeasureRest: Int?` field. The renderer dispatches a new
`LayoutElement.multiMeasureRest(count:origin:)` case to draw the
SMuFL `restHBar` glyph plus the count above the staff.

**Tech Stack:** Swift 6, Swift Testing (`@Test` / `#expect`),
SwiftUI / Core Animation, SMuFL / Bravura.

**Spec:** `docs/superpowers/specs/2026-05-10-multi-measure-rest-design.md`

**Working tree:** main project directory; no worktree split needed
(net additive; no risky refactors).

---

## File structure

**Create:**
- `Sources/SheetMusicLayout/Layout/MultiMeasureRestPlanner.swift`
  — pure planner + `MultiMeasureRestPlan` value type.
- `Sources/SheetMusicUI/Rendering/MultiMeasureRestRenderer.swift`
  — H-bar glyph + count text drawer.
- `Tests/SheetMusicTests/MultiMeasureRestPlannerTests.swift`
  — pure-logic tests.
- `Tests/SheetMusicTests/MultiMeasureRestLayoutTests.swift`
  — layout integration tests.

**Modify:**
- `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`
  — add `MultiMeasureRestPolicy` enum + new field on
  `ScoreViewOptions`.
- `Sources/SheetMusicLayout/Layout/LayoutElement.swift`
  — add `.multiMeasureRest(count: Int, origin: CGPoint)` case.
- `Sources/SheetMusicLayout/Layout/LayoutMeasure.swift`
  — add `multiMeasureRest: Int?` field (nil for normal measures).
- `Sources/SheetMusicLayout/Layout/LayoutEngine.swift`
  — compute plan once; carry on `RenderContext`.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Packing.swift`
  — collapsed-width override; skip-aware iteration in
  `packSystems`.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift`
  — skip interior indices; emit run-start as collapsed measure.
- `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift`
  — add `restHBar` constant + thin variant glyphs.
- `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift`
  — dispatch the new `LayoutElement` case.
- `Sources/RenderPreviews/Samples.swift`
  — add `multiMeasureRest` sample score (8 rest measures with a
  sounding measure on each side).
- `Sources/RenderPreviews/main.swift`
  — register the new sample in the output list.

---

## Task 1: Add `MultiMeasureRestPolicy` (no-op)

**Files:**
- Modify: `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`
- Test: `Tests/SheetMusicTests/ScoreViewOptionsTests.swift` (create
  if missing — confirm by listing the directory first)

- [ ] **Step 1: Inspect the existing options file**

Run: `cat Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`

Confirm `LayoutBreakPolicy` is declared in the same file and that
`ScoreViewOptions.init` has the order documented in the spec.

- [ ] **Step 2: Write a failing test**

Create `Tests/SheetMusicTests/ScoreViewOptionsTests.swift` (or
append a new `@Suite` to it if it already exists):

```swift
#if os(macOS) || os(iOS)
import SheetMusicLayout
import Testing

@Suite("ScoreViewOptions multiMeasureRest")
struct ScoreViewOptionsMultiMeasureRestTests {
    @Test("default is .disabled")
    func defaultDisabled() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let opts = ScoreViewOptions()
        #expect(opts.multiMeasureRest == .disabled)
    }

    @Test("collapse case carries minimum")
    func collapseCarriesMinimum() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let opts = ScoreViewOptions(
            multiMeasureRest: .collapse(minimumMeasures: 4)
        )
        if case let .collapse(min) = opts.multiMeasureRest {
            #expect(min == 4)
        } else {
            Issue.record("expected .collapse")
        }
    }
}
#endif
```

- [ ] **Step 3: Run the test to confirm failure**

Run: `swift test --filter ScoreViewOptionsMultiMeasureRestTests`
Expected: FAIL — "type 'ScoreViewOptions' has no member
'multiMeasureRest'" or similar compile error.

- [ ] **Step 4: Add the enum + field**

Edit `Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`.
Add the enum below `LayoutBreakPolicy`:

```swift
/// Policy for collapsing runs of consecutive rest measures into a
/// single multi-measure-rest bar (the H-bar + count notation).
/// Affects layout only — `Score` and MIDI are untouched.
@available(macOS 15.0, iOS 16.0, *)
public enum MultiMeasureRestPolicy: Sendable, Equatable {
    /// Default — every rest measure renders individually.
    case disabled

    /// Collapse runs of `>= minimumMeasures` consecutive rest
    /// measures into one H-bar. Typical value is 2. Values < 2 are
    /// clamped to 2 by the planner.
    case collapse(minimumMeasures: Int)
}
```

Then add the field on `ScoreViewOptions`:

```swift
public var multiMeasureRest: MultiMeasureRestPolicy
```

…and extend the initializer (append the new parameter at the end so
existing call sites continue to compile):

```swift
public init(
    staffSize: CGFloat = 28,
    systemGap: CGFloat = 40,
    wrapToViewWidth: Bool = true,
    includeTitleFrame: Bool = true,
    breakPolicy: LayoutBreakPolicy = .honor,
    showBreakIndicators: Bool = true,
    graceNoteMag: CGFloat = 0.6,
    multiMeasureRest: MultiMeasureRestPolicy = .disabled
) {
    self.staffSize = staffSize
    self.systemGap = systemGap
    self.wrapToViewWidth = wrapToViewWidth
    self.includeTitleFrame = includeTitleFrame
    self.breakPolicy = breakPolicy
    self.showBreakIndicators = showBreakIndicators
    self.graceNoteMag = graceNoteMag
    self.multiMeasureRest = multiMeasureRest
}
```

- [ ] **Step 5: Run the test to confirm pass**

Run: `swift test --filter ScoreViewOptionsMultiMeasureRestTests`
Expected: PASS, both tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Options/ScoreViewOptions.swift \
        Tests/SheetMusicTests/ScoreViewOptionsTests.swift
git commit -m "layout: add MultiMeasureRestPolicy on ScoreViewOptions

Net-additive option whose default (.disabled) reproduces existing
layout behavior. Future tasks will read this option to drive the
collapse pass."
```

---

## Task 2: Write planner predicate tests

This task introduces `MultiMeasureRestPlanner` *only via the test file*
— no implementation yet. Each test compiles against the API the
planner will expose; running them confirms what we still need to
build.

**Files:**
- Create: `Tests/SheetMusicTests/MultiMeasureRestPlannerTests.swift`

- [ ] **Step 1: Write the test scaffolding + first batch of tests**

Create `Tests/SheetMusicTests/MultiMeasureRestPlannerTests.swift`:

```swift
#if os(macOS) || os(iOS)
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@available(macOS 15.0, iOS 16.0, *)
@Suite("MultiMeasureRestPlanner")
struct MultiMeasureRestPlannerTests {
    // MARK: - Helpers

    private static func restMeasure() -> Measure {
        Measure(voices: [Voice(elements: [.rest(duration: .whole)])])
    }

    private static func soundingMeasure() -> Measure {
        let n = Note(pitch: 60, tpc: 14)
        return Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [n])),
        ])])
    }

    private static func score(_ measures: [Measure]) -> Score {
        Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: measures)]
            )]
        )
    }

    // MARK: - Tests

    @Test("disabled returns an empty plan")
    func disabledReturnsEmptyPlan() {
        let s = Self.score([
            Self.restMeasure(), Self.restMeasure(), Self.restMeasure(),
        ])
        let plan = MultiMeasureRestPlanner.plan(for: s, policy: .disabled)
        #expect(plan.runs.isEmpty)
    }

    @Test("three rest measures collapse with minimum 2")
    func threeRestsCollapseWithMinimumTwo() {
        let s = Self.score([
            Self.restMeasure(), Self.restMeasure(), Self.restMeasure(),
        ])
        let plan = MultiMeasureRestPlanner.plan(
            for: s, policy: .collapse(minimumMeasures: 2)
        )
        #expect(plan.runs == [0 ..< 3])
    }

    @Test("two rests do not collapse when minimum is 3")
    func twoRestsBelowMinimumDoNotCollapse() {
        let s = Self.score([Self.restMeasure(), Self.restMeasure()])
        let plan = MultiMeasureRestPlanner.plan(
            for: s, policy: .collapse(minimumMeasures: 3)
        )
        #expect(plan.runs.isEmpty)
    }

    @Test("minimum below 2 is clamped to 2")
    func minimumBelowTwoIsClampedToTwo() {
        let s = Self.score([Self.restMeasure()])
        let plan = MultiMeasureRestPlanner.plan(
            for: s, policy: .collapse(minimumMeasures: 1)
        )
        // Single rest cannot collapse even when minimum is 1 (clamped to 2).
        #expect(plan.runs.isEmpty)
    }

    @Test("sounding measure breaks the run")
    func soundingMeasureBreaksRun() {
        let s = Self.score([
            Self.restMeasure(), Self.restMeasure(),
            Self.soundingMeasure(),
            Self.restMeasure(), Self.restMeasure(),
        ])
        let plan = MultiMeasureRestPlanner.plan(
            for: s, policy: .collapse(minimumMeasures: 2)
        )
        #expect(plan.runs == [0 ..< 2, 3 ..< 5])
    }
}
#endif
```

- [ ] **Step 2: Run to confirm compile failure**

Run: `swift test --filter MultiMeasureRestPlannerTests`
Expected: FAIL — "cannot find 'MultiMeasureRestPlanner' in scope".

- [ ] **Step 3: Append the run-break tests**

Open the same file and append these tests *inside* the existing
`@Suite` struct:

```swift
@Test("rehearsal mark in voice breaks run")
func rehearsalMarkBreaksRun() {
    let mark = Measure(voices: [Voice(elements: [
        .rehearsalMark(RehearsalMark(text: "A")),
        .rest(duration: .whole),
    ])])
    let s = Self.score([
        Self.restMeasure(), Self.restMeasure(), mark,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    // The mark-bearing measure is not collapsible; trailing pair collapses.
    #expect(plan.runs == [0 ..< 2, 3 ..< 5])
}

@Test("key signature change breaks run")
func keySignatureChangeBreaksRun() {
    let keyChange = Measure(voices: [Voice(elements: [
        .keySignature(KeySignature(concertKey: 2)),
        .rest(duration: .whole),
    ])])
    let s = Self.score([
        Self.restMeasure(), Self.restMeasure(),
        keyChange,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [0 ..< 2, 3 ..< 5])
}

@Test("time signature change breaks run")
func timeSignatureChangeBreaksRun() {
    let tsChange = Measure(voices: [Voice(elements: [
        .timeSignature(TimeSignature(numerator: 3, denominator: 4)),
        .rest(duration: .whole),
    ])])
    let s = Self.score([
        Self.restMeasure(), Self.restMeasure(),
        tsChange,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [0 ..< 2, 3 ..< 5])
}

@Test("tempo change breaks run")
func tempoChangeBreaksRun() {
    let tempoMeasure = Measure(voices: [Voice(elements: [
        .tempo(Tempo(beatsPerSecond: 2.0)),
        .rest(duration: .whole),
    ])])
    let s = Self.score([
        Self.restMeasure(), Self.restMeasure(),
        tempoMeasure,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [0 ..< 2, 3 ..< 5])
}

@Test("startRepeat breaks run before the marked measure")
func startRepeatBreaksRun() {
    var m = Self.restMeasure()
    m.startRepeat = true
    let s = Self.score([
        Self.restMeasure(), Self.restMeasure(), m,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [0 ..< 2, 3 ..< 5])
}

@Test("endRepeat breaks run inclusive of the marked measure")
func endRepeatBreaksRun() {
    var m = Self.restMeasure()
    m.endRepeatCount = 2
    let s = Self.score([
        Self.restMeasure(), m,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [2 ..< 4])
}

@Test("measure-level marker breaks run")
func markerBreaksRun() {
    var m = Self.restMeasure()
    m.markers = [Marker(kind: .segno, text: "")]
    let s = Self.score([
        Self.restMeasure(), Self.restMeasure(), m,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [0 ..< 2, 3 ..< 5])
}

@Test("measure-level jump breaks run")
func jumpBreaksRun() {
    var m = Self.restMeasure()
    m.jumps = [Jump(kind: .dc, text: "D.C.")]
    let s = Self.score([
        Self.restMeasure(), Self.restMeasure(), m,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [0 ..< 2, 3 ..< 5])
}

@Test("authored line break closes the run at that measure")
func lineBreakClosesRun() {
    var m1 = Self.restMeasure()
    m1.lineBreak = true
    let s = Self.score([
        m1, Self.restMeasure(), Self.restMeasure(),
        Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    // m0 has lineBreak → run ends after it. m0 is still collapsible
    // by itself, but a run of 1 doesn't meet the minimum.
    // m1..m3 form a collapsible run of 3.
    #expect(plan.runs == [1 ..< 4])
}

@Test("page break closes the run at that measure")
func pageBreakClosesRun() {
    var m1 = Self.restMeasure()
    m1.pageBreak = true
    let s = Self.score([
        Self.restMeasure(), m1,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    // m0..m1 form a 2-measure run that ends at m1 (pageBreak closes
    // after m1). m2..m3 form a separate 2-measure run.
    #expect(plan.runs == [0 ..< 2, 2 ..< 4])
}

@Test("irregular measure is not collapsible")
func irregularMeasureNotCollapsible() {
    var m = Self.restMeasure()
    m.irregular = true
    let s = Self.score([
        Self.restMeasure(), Self.restMeasure(),
        m,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [0 ..< 2, 3 ..< 5])
}

@Test("actualLength override is not collapsible")
func actualLengthOverrideNotCollapsible() {
    var m = Self.restMeasure()
    m.actualLength = Fraction(numerator: 2, denominator: 4)
    let s = Self.score([
        Self.restMeasure(), Self.restMeasure(),
        m,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [0 ..< 2, 3 ..< 5])
}

@Test("measure-repeat group member is not collapsible")
func measureRepeatNotCollapsible() {
    var m = Self.restMeasure()
    m.measureRepeatCount = 1
    let s = Self.score([
        Self.restMeasure(), Self.restMeasure(),
        m,
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [0 ..< 2, 3 ..< 5])
}

@Test("open spanner crossing the run blocks collapse")
func openSpannerBlocksCollapse() {
    // m0 starts a 4-measure spanner. Even though m1..m3 are rest
    // measures, the spanner is still open across them, so the run
    // is blocked.
    let pedal = Spanner(
        kind: .pedal, rawType: "Pedal",
        nextMeasuresOffset: 4
    )
    let m0 = Measure(voices: [Voice(elements: [
        .spanner(pedal),
        .rest(duration: .whole),
    ])])
    let s = Self.score([
        m0,
        Self.restMeasure(), Self.restMeasure(),
        Self.restMeasure(),
        Self.restMeasure(), Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    // Pedal runs from m0 across m0..m3 inclusive; closed before m4.
    // m4..m5 collapse normally.
    #expect(plan.runs == [4 ..< 6])
}

@Test("multiple staves: collapse only when every staff is silent")
func multipleStavesAllSilent() {
    let r = Self.restMeasure()
    let n = Self.soundingMeasure()
    let s = Score(
        division: 480,
        parts: [Part(
            id: "1",
            instrument: Instrument(id: "x"),
            staves: [
                // Staff 0: r, r, r
                Staff(measures: [r, r, r]),
                // Staff 1: r, n, r — middle measure has a note
                Staff(measures: [r, n, r]),
            ]
        )]
    )
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    // Only m0 and m2 are silent across all staves. They are
    // separated by m1, so neither qualifies as a 2-measure run.
    #expect(plan.runs.isEmpty)
}

@Test("location shift alone does not break run")
func locationShiftIsCollapsible() {
    let m = Measure(voices: [Voice(elements: [
        .locationShift(delta: Fraction(numerator: 1, denominator: 8)),
        .rest(duration: .whole),
    ])])
    let s = Self.score([
        Self.restMeasure(), m, Self.restMeasure(),
    ])
    let plan = MultiMeasureRestPlanner.plan(
        for: s, policy: .collapse(minimumMeasures: 2)
    )
    #expect(plan.runs == [0 ..< 3])
}
```

- [ ] **Step 4: Run to confirm all tests fail to compile**

Run: `swift test --filter MultiMeasureRestPlannerTests`
Expected: FAIL — same "cannot find" error. None of these tests can
run yet. We'll move them to PASS in Task 3.

- [ ] **Step 5: Commit (test-only)**

```bash
git add Tests/SheetMusicTests/MultiMeasureRestPlannerTests.swift
git commit -m "tests(layout): add MultiMeasureRestPlanner tests

Compile-failing fixtures that pin the planner's predicate (rules
1-9 in the spec) before the implementation lands. All tests run
in Task 3."
```

---

## Task 3: Implement `MultiMeasureRestPlanner`

**Files:**
- Create: `Sources/SheetMusicLayout/Layout/MultiMeasureRestPlanner.swift`

- [ ] **Step 1: Create the planner file**

```swift
import SheetMusicCore

/// Plan describing how a `MultiMeasureRestPlanner` would group
/// consecutive rest measures into a single H-bar bar at layout
/// time. Pure data; no references to layout primitives.
@available(macOS 15.0, iOS 16.0, *)
public struct MultiMeasureRestPlan: Sendable, Equatable {
    /// Sorted, non-overlapping ranges of measure indices to collapse.
    /// `runs[i].lowerBound` is the bar that draws the H-bar; the
    /// remaining indices in the half-open range are skipped by
    /// `LayoutEngine`.
    public let runs: [Range<Int>]

    public init(runs: [Range<Int>] = []) { self.runs = runs }

    /// `runs` entry containing `measureIndex`, or nil when the
    /// measure renders individually.
    public func run(containing measureIndex: Int) -> Range<Int>? {
        // Linear scan is fine: real-world plans have at most a
        // handful of runs.
        runs.first { $0.contains(measureIndex) }
    }

    /// True when `measureIndex` sits inside a run *but is not the
    /// run's first measure*. Layout uses this to skip emission.
    public func isInteriorOfRun(_ measureIndex: Int) -> Bool {
        guard let r = run(containing: measureIndex) else { return false }
        return measureIndex != r.lowerBound
    }

    /// Length of the run starting at `measureIndex`, or nil when
    /// `measureIndex` is not a run-start.
    public func runLength(startingAt measureIndex: Int) -> Int? {
        guard let r = run(containing: measureIndex),
              r.lowerBound == measureIndex
        else { return nil }
        return r.count
    }
}

/// Pure: walks `score` once and emits the maximal collapsible runs
/// allowed under `policy`. See spec §"Run-break rules" for the
/// predicate. The planner does not mutate `score` and is safe to
/// call repeatedly with the same arguments (idempotent).
@available(macOS 15.0, iOS 16.0, *)
public enum MultiMeasureRestPlanner {
    public static func plan(
        for score: Score,
        policy: MultiMeasureRestPolicy
    ) -> MultiMeasureRestPlan {
        guard case let .collapse(rawMin) = policy else {
            return MultiMeasureRestPlan()
        }
        let minimum = max(2, rawMin)
        let staves = score.parts.flatMap(\.staves)
        guard let measureCount = staves.first?.measures.count,
              measureCount > 0
        else { return MultiMeasureRestPlan() }

        // Per-measure open-spanner depth at the *start* of measure i.
        // Built first because per-measure collapsibility consults it.
        let openDepth = openSpannerDepth(
            staves: staves, measureCount: measureCount
        )

        var runs: [Range<Int>] = []
        var runStart: Int? = nil
        for i in 0 ..< measureCount {
            let collapsible = isCollapsible(
                measureIndex: i,
                staves: staves,
                openDepthAtStart: openDepth[i]
            )
            if collapsible, runStart == nil {
                runStart = i
            }
            // An authored break on `i` (lineBreak/pageBreak) closes
            // the run *after* `i`. Determine that after this
            // measure is appended.
            let breaksAfter = anyStaffBreaksAfter(
                measureIndex: i, staves: staves
            )
            if !collapsible {
                if let s = runStart {
                    appendIfMeetsMinimum(
                        s ..< i, into: &runs, minimum: minimum
                    )
                    runStart = nil
                }
            } else if breaksAfter {
                if let s = runStart {
                    appendIfMeetsMinimum(
                        s ..< (i + 1), into: &runs, minimum: minimum
                    )
                    runStart = nil
                }
            }
        }
        if let s = runStart {
            appendIfMeetsMinimum(
                s ..< measureCount, into: &runs, minimum: minimum
            )
        }
        return MultiMeasureRestPlan(runs: runs)
    }

    // MARK: - Predicate

    private static func isCollapsible(
        measureIndex i: Int,
        staves: [Staff],
        openDepthAtStart: Int
    ) -> Bool {
        // Rule 6 (open-spanner check) is a *whole-measure* state:
        // any spanner active at the start of `i` blocks collapse,
        // and any spanner that *opens* in `i` will also be visible
        // (caught below by the per-element scan).
        guard openDepthAtStart == 0 else { return false }
        for staff in staves {
            guard i < staff.measures.count else { return false }
            let m = staff.measures[i]
            // Rules 2–5.
            guard !m.startRepeat,
                  m.endRepeatCount == nil,
                  m.markers.isEmpty,
                  m.jumps.isEmpty,
                  m.measureRepeatCount == nil,
                  !m.irregular,
                  m.actualLength == nil
            else { return false }
            // Rule 1: every voice element is a rest or location shift,
            // and tuplets are absent.
            for voice in m.voices {
                guard voice.tuplets.isEmpty else { return false }
                for el in voice.elements {
                    switch el {
                    case let .chord(c) where c.notes.isEmpty:
                        continue
                    case .locationShift:
                        continue
                    default:
                        return false
                    }
                }
            }
        }
        return true
    }

    private static func anyStaffBreaksAfter(
        measureIndex i: Int, staves: [Staff]
    ) -> Bool {
        for staff in staves {
            guard i < staff.measures.count else { continue }
            let m = staff.measures[i]
            if m.lineBreak || m.pageBreak { return true }
        }
        return false
    }

    private static func appendIfMeetsMinimum(
        _ range: Range<Int>,
        into runs: inout [Range<Int>],
        minimum: Int
    ) {
        if range.count >= minimum { runs.append(range) }
    }

    // MARK: - Spanner depth

    /// `result[i]` is the count of spanners that began at measure
    /// `j < i` and remain open at the start of `i`. A spanner with
    /// `nextMeasuresOffset = k` started at `j` covers measures
    /// `j..<(j+k)` (i.e. closes before `j+k`).
    private static func openSpannerDepth(
        staves: [Staff], measureCount: Int
    ) -> [Int] {
        // Counts increment when a spanner opens, decrement at the
        // close index. We emit `+1` at `start` (so depth is
        // visible at `start`'s own collapsibility check) — but the
        // predicate already rejects measures whose voice elements
        // contain a spanner directly, so opening-measure double
        // counting is moot. We still need to decrement at the
        // close index so depth at `i > start` is correct.
        var delta = Array(repeating: 0, count: measureCount + 1)
        for staff in staves {
            for (i, m) in staff.measures.enumerated() {
                for voice in m.voices {
                    for el in voice.elements {
                        guard case let .spanner(s) = el else { continue }
                        let span = max(0, s.nextMeasuresOffset)
                        let close = min(measureCount, i + span + 1)
                        if i < measureCount { delta[i] += 1 }
                        if close <= measureCount { delta[close] -= 1 }
                    }
                }
            }
        }
        var depth = Array(repeating: 0, count: measureCount)
        var running = 0
        for i in 0 ..< measureCount {
            running += delta[i]
            depth[i] = running
        }
        return depth
    }
}
```

- [ ] **Step 2: Run the planner tests**

Run: `swift test --filter MultiMeasureRestPlannerTests`
Expected: PASS for every test added in Task 2.

- [ ] **Step 3: If a test fails, debug then re-run**

Read the failing assertion. Most likely culprits:

- *Spanner depth* — re-check `delta[close] -= 1`. The spec says a
  spanner with `nextMeasuresOffset = k` covers exactly `k+1`
  measures (start + k more), so closing index is `start + k + 1`.
  The MuseScore convention varies; verify against
  `multipleStavesAllSilent` and `openSpannerBlocksCollapse`.
- *Off-by-one on lineBreak* — `lineBreakClosesRun` expects
  `[1..<4]`. m0 has lineBreak, so the run there is `[0..<1]`
  (length 1, below minimum), and the new run starts at m1.

- [ ] **Step 4: Lint pass**

Run: `swiftlint --quiet Sources/SheetMusicLayout/Layout/MultiMeasureRestPlanner.swift`
Expected: 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/MultiMeasureRestPlanner.swift
git commit -m "layout: implement MultiMeasureRestPlanner

Pure planner over (Score, MultiMeasureRestPolicy) → list of
collapsible measure-index runs. Used in subsequent tasks by the
layout engine to emit H-bar measures."
```

---

## Task 4: Add `LayoutElement.multiMeasureRest` + `LayoutMeasure.multiMeasureRest`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutMeasure.swift`

- [ ] **Step 1: Add the LayoutElement case**

Open `Sources/SheetMusicLayout/Layout/LayoutElement.swift`. After
the existing `case measureRepeat(count: Int, origin: CGPoint)`
line, add:

```swift
/// Multi-measure rest H-bar with a count printed above. Replaces
/// the `count` consecutive rest measures starting at this layout
/// measure's `measureIndex`. Origin is the SMuFL anchor at the
/// horizontal center of the measure, vertically centered on the
/// middle staff line.
case multiMeasureRest(
    count: Int,
    origin: CGPoint
)
```

- [ ] **Step 2: Add the LayoutMeasure flag**

Open `Sources/SheetMusicLayout/Layout/LayoutMeasure.swift`. Add a
new field:

```swift
/// When non-nil, this layout measure renders as a multi-measure-rest
/// H-bar covering `multiMeasureRest!` source measures. The
/// `elements` array carries the H-bar `LayoutElement` plus
/// surrounding barlines; no chord/rest elements are emitted.
public let multiMeasureRest: Int?
```

…and extend `init` (place the new parameter at the end with default
`nil` so existing call sites continue to compile):

```swift
public init(
    measureIndex: Int,
    origin: CGPoint,
    width: CGFloat,
    elements: [LayoutElement],
    markers: [LayoutElement] = [],
    jumps: [LayoutElement] = [],
    lineBreak: Bool = false,
    pageBreak: Bool = false,
    tickColumns: [Int: CGFloat] = [:],
    multiMeasureRest: Int? = nil
) {
    self.measureIndex = measureIndex
    self.origin = origin
    self.width = width
    self.elements = elements
    self.markers = markers
    self.jumps = jumps
    self.lineBreak = lineBreak
    self.pageBreak = pageBreak
    self.tickColumns = tickColumns
    self.multiMeasureRest = multiMeasureRest
}
```

- [ ] **Step 3: Build to surface exhaustive-switch breaks**

Run: `swift build`
Expected: error(s) of the form "switch must be exhaustive" in
files that switch on `LayoutElement`. Likely sites:

- `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift`
  (the central dispatch)
- Any `switch` over `LayoutElement` in `SheetMusicLayout/Layout/`
  (YBounds, Translate, Selection — these accept "ignore" defaults)

- [ ] **Step 4: Add stub branches to each broken switch**

For every site the build flagged, add a no-op branch:

```swift
case .multiMeasureRest:
    // Drawn by MultiMeasureRestRenderer in Task 11. No
    // contribution to ybounds / spanner attach / tie attach.
    break
```

(or `return nil` / `return .zero` matching the surrounding switch's
return type — copy the shape of the existing `.beam` / `.barLine`
branch in the same switch.)

- [ ] **Step 5: Build clean**

Run: `swift build`
Expected: 0 errors, 0 warnings (excluding pre-existing warnings).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutElement.swift \
        Sources/SheetMusicLayout/Layout/LayoutMeasure.swift \
        Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift \
        $(git diff --name-only Sources/)
git commit -m "layout: add multiMeasureRest to LayoutElement + LayoutMeasure

Net-additive surface area; renderer wiring in a follow-up task."
```

---

## Task 5: Plumb the plan through `RenderContext`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine.swift`

- [ ] **Step 1: Add the field on `RenderContext`**

Inside `LayoutEngine`'s `RenderContext` struct (bottom of
`LayoutEngine.swift`), append:

```swift
/// Run plan for the multi-measure-rest collapse pass. Empty when
/// `options.multiMeasureRest == .disabled`.
let multiMeasureRestPlan: MultiMeasureRestPlan
```

- [ ] **Step 2: Compute the plan once in `LayoutEngine.layout`**

In the cache-aware overload, add the plan computation to the
`RenderContext` initializer call:

```swift
let plan = MultiMeasureRestPlanner.plan(
    for: score, policy: options.multiMeasureRest
)
let context = RenderContext(
    score: score,
    options: options,
    metrics: metrics,
    availableWidth: availableWidth,
    melismaContinuations: melismas,
    effectiveMelismaTicks: effectiveMelismaTicks,
    cache: cache,
    belowStaffSpannerCoverage: belowStaffSpannerCoverage(score: score),
    multiMeasureRestPlan: plan
)
```

(Insert the new field at the end of the parameter list to mirror
the field ordering in the struct.)

- [ ] **Step 3: Build clean**

Run: `swift build`
Expected: 0 errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine.swift
git commit -m "layout: compute MultiMeasureRestPlan once on RenderContext

Threaded through context so packSystems / buildSystem can consume
it without re-invoking the planner per measure."
```

---

## Task 6: Width override + skip in `packSystems`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Packing.swift`

- [ ] **Step 1: Override `minWidths` for run-aware indices**

Locate the `minWidths` calculation (the `(0 ..< measureCount).map`
block in `packSystems`). After the existing per-measure width is
computed but before the cache-store, override the width when the
plan applies:

```swift
let minWidths: [CGFloat] = (0 ..< measureCount).map { i in
    // ... existing cache-hit short-circuit and compute path ...

    // Multi-measure-rest collapse: a run-start gets a fixed
    // collapsed width, run-interior measures contribute zero so
    // the system packing skips over them.
    let plan = context.multiMeasureRestPlan
    if let runLen = plan.runLength(startingAt: i) {
        _ = runLen  // emission consumes this in buildSystem
        let collapsedWidth = collapsedRunWidth(
            staffSpace: context.metrics.sp
        )
        // Update the cached entry's minWidth so cache hits also
        // see the collapsed value.
        if var entry = context.cache?.entries[i] {
            entry.minWidth = collapsedWidth
            context.cache?.entries[i] = entry
        }
        return collapsedWidth
    } else if plan.isInteriorOfRun(i) {
        if var entry = context.cache?.entries[i] {
            entry.minWidth = 0
            context.cache?.entries[i] = entry
        }
        return 0
    }
    return /* existing computed width */
}
```

> **Implementation note for the engineer:** the existing block is
> ~40 lines and threads through cache stores. Don't paste the
> snippet above blind — instead wrap the *return* of the existing
> closure. Use a local helper:
>
> ```swift
> func collapsedOverride(
>     for i: Int, baseline: CGFloat
> ) -> CGFloat {
>     if context.multiMeasureRestPlan.runLength(startingAt: i) != nil {
>         return collapsedRunWidth(staffSpace: context.metrics.sp)
>     }
>     if context.multiMeasureRestPlan.isInteriorOfRun(i) {
>         return 0
>     }
>     return baseline
> }
> ```
>
> Then call it once on every return path (cache-hit and miss) and
> mirror the returned value into the cache entry on miss.

- [ ] **Step 2: Define `collapsedRunWidth`**

Add to the same file (top of the `extension LayoutEngine` block):

```swift
/// Fixed width of a multi-measure-rest collapsed bar. v1 uses a
/// constant `~6 * sp` regardless of `count`; the count above the
/// bar conveys magnitude, and a `log(N)` taper can be layered on
/// later behind the same field.
static func collapsedRunWidth(staffSpace sp: CGFloat) -> CGFloat {
    sp * 6
}
```

- [ ] **Step 3: Skip interior measures in the system-fill loop**

Inside the inner `while cursor < measureCount` loop in
`packSystems`, before reading `minWidths[cursor]`, jump past
interior indices in one step:

```swift
while cursor < measureCount {
    // Multi-measure-rest interior measures contribute width 0 and
    // emit nothing; the run-start at `cursor.lowerBound` already
    // accounted for the collapsed width. Advance cursor past the
    // interior in a single jump so layout-break inspection stays
    // anchored on the run's start.
    if context.multiMeasureRestPlan.isInteriorOfRun(cursor) {
        cursor += 1
        continue
    }
    // ... existing body ...
}
```

> **Note:** *do not* modify `widthsSlice = Array(minWidths[systemStart ..< cursor])`.
> Keeping `widthsSlice` index-aligned with the source measure
> range (interior entries = 0) is what lets `buildSystem` keep its
> existing iteration shape.

- [ ] **Step 4: Build clean**

Run: `swift build`
Expected: 0 errors.

- [ ] **Step 5: Manual smoke check — disabled policy is unchanged**

Run: `swift test --filter LayoutCacheTests`
Expected: PASS (these tests use `.init()` defaults, which include
`.disabled`, so packing must be byte-identical).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Packing.swift
git commit -m "layout: collapsed-run width + interior skip in packSystems

Run-start indices contribute `6 * sp`; run-interior indices
contribute zero and the cursor skips them. Disabled policy
yields the same widths as before (verified by LayoutCacheTests)."
```

---

## Task 7: Emit collapsed measure in `buildSystem`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift`

- [ ] **Step 1: Read the current per-measure emission loop**

Run: `grep -n "for.*in.*measureRange\|var measureX" Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift | head -5`

Find the loop that maps over `measureRange` and produces a
`LayoutMeasure` per index. Identify the variable that accumulates
horizontal position (typically `measureX` or `cursorX`).

- [ ] **Step 2: Branch the emission for run starts**

Inside that loop, before the existing per-measure body, insert a
branch:

```swift
let plan = context.multiMeasureRestPlan
if plan.isInteriorOfRun(measureIdx) {
    // Interior of a run already covered by the run-start emission.
    // Width is zero; nothing to emit and `cursorX` does not advance.
    continue
}
if let runLen = plan.runLength(startingAt: measureIdx) {
    let collapsed = makeMultiMeasureRestMeasure(
        measureIndex: measureIdx,
        runLength: runLen,
        originX: cursorX,
        width: widths[measureIdx - measureRange.lowerBound],
        metrics: context.metrics
    )
    measures.append(collapsed)
    cursorX += collapsed.width
    continue
}
```

(Substitute the actual loop / accumulator / measures-array names
from your local read.)

- [ ] **Step 3: Add the `makeMultiMeasureRestMeasure` helper**

Append at the bottom of the same file (still inside the
`extension LayoutEngine`):

```swift
/// Build a `LayoutMeasure` for a run of `runLength` collapsed rest
/// measures. Emits one barline at the right edge plus the H-bar
/// element vertically centered on the staff. Run interiors are
/// skipped by the caller — only the run-start is emitted.
@available(macOS 15.0, iOS 16.0, *)
static func makeMultiMeasureRestMeasure(
    measureIndex: Int,
    runLength: Int,
    originX: CGFloat,
    width: CGFloat,
    metrics: StaffMetrics
) -> LayoutMeasure {
    let centerX = width / 2
    let centerY = metrics.staffHeight / 2
    let hbar = LayoutElement.multiMeasureRest(
        count: runLength,
        origin: CGPoint(x: centerX, y: centerY)
    )
    // Right-edge barline mirrors the normal-measure emission so
    // adjacent measures don't lose their separator.
    let bar = LayoutElement.barLine(
        subtype: nil,
        origin: CGPoint(x: width, y: 0)
    )
    return LayoutMeasure(
        measureIndex: measureIndex,
        origin: CGPoint(x: originX, y: 0),
        width: width,
        elements: [hbar, bar],
        multiMeasureRest: runLength
    )
}
```

> If the existing per-measure emission already appends a barline
> in a separate pass (e.g. via `appendBarLines` or similar),
> *don't* duplicate it here — drop the `bar` element from `elements`
> and let the existing pass run.

- [ ] **Step 4: Build clean**

Run: `swift build`
Expected: 0 errors.

- [ ] **Step 5: Re-run the cache test**

Run: `swift test --filter LayoutCacheTests`
Expected: PASS — disabled policy still produces unchanged output.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift
git commit -m "layout: emit collapsed measure for multi-measure-rest runs

Run-start indices produce one LayoutMeasure carrying the H-bar
LayoutElement. Run-interior indices are skipped — the measure
loop continues without advancing cursorX or appending a measure."
```

---

## Task 8: Layout integration tests

**Files:**
- Create: `Tests/SheetMusicTests/MultiMeasureRestLayoutTests.swift`

- [ ] **Step 1: Write the integration tests**

```swift
#if os(macOS) || os(iOS)
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@available(macOS 15.0, iOS 16.0, *)
@Suite("MultiMeasureRest layout integration")
struct MultiMeasureRestLayoutTests {
    private static func restMeasure() -> Measure {
        Measure(voices: [Voice(elements: [.rest(duration: .whole)])])
    }

    private static func soundingMeasure() -> Measure {
        let n = Note(pitch: 60, tpc: 14)
        return Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [n])),
        ])])
    }

    private static func score(_ measures: [Measure]) -> Score {
        Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: measures)]
            )]
        )
    }

    @Test(".disabled emits one LayoutMeasure per source measure")
    func disabledPolicyUnchanged() {
        let s = Self.score([
            Self.soundingMeasure(),
            Self.restMeasure(), Self.restMeasure(),
            Self.restMeasure(), Self.restMeasure(),
            Self.soundingMeasure(),
        ])
        let doc = LayoutEngine.layout(
            score: s, options: ScoreViewOptions(),
            availableWidth: 1200
        )
        let total = doc.systems.reduce(0) { $0 + $1.measures.count }
        #expect(total == 6)
        for sys in doc.systems {
            for m in sys.measures {
                #expect(m.multiMeasureRest == nil)
            }
        }
    }

    @Test(".collapse(2) emits one H-bar measure for the rest run")
    func collapsedEmitsOneHBarMeasure() {
        let s = Self.score([
            Self.soundingMeasure(),
            Self.restMeasure(), Self.restMeasure(),
            Self.restMeasure(), Self.restMeasure(),
            Self.soundingMeasure(),
        ])
        let opts = ScoreViewOptions(
            multiMeasureRest: .collapse(minimumMeasures: 2)
        )
        let doc = LayoutEngine.layout(
            score: s, options: opts, availableWidth: 1200
        )
        let allMeasures = doc.systems.flatMap(\.measures)
        // Sounding + H-bar + sounding = 3 emitted measures.
        #expect(allMeasures.count == 3)
        let hbar = allMeasures.first { $0.multiMeasureRest != nil }
        #expect(hbar?.multiMeasureRest == 4)
        // Source-measure indices preserved.
        let indices = allMeasures.map(\.measureIndex)
        #expect(indices == [0, 1, 5])
    }

    @Test("collapsed measure carries multiMeasureRest LayoutElement")
    func collapsedMeasureCarriesElement() {
        let s = Self.score([
            Self.restMeasure(), Self.restMeasure(),
            Self.restMeasure(),
        ])
        let opts = ScoreViewOptions(
            multiMeasureRest: .collapse(minimumMeasures: 2)
        )
        let doc = LayoutEngine.layout(
            score: s, options: opts, availableWidth: 800
        )
        let hbar = doc.systems.flatMap(\.measures)
            .first { $0.multiMeasureRest != nil }
        guard let hbar else {
            Issue.record("no H-bar measure emitted")
            return
        }
        let counts = hbar.elements.compactMap {
            if case let .multiMeasureRest(n, _) = $0 { return n }
            return nil
        }
        #expect(counts == [3])
    }

    @Test("rehearsal mark splits the run")
    func rehearsalMarkSplitsRun() {
        let mark = Measure(voices: [Voice(elements: [
            .rehearsalMark(RehearsalMark(text: "A")),
            .rest(duration: .whole),
        ])])
        let s = Self.score([
            Self.restMeasure(), Self.restMeasure(),
            mark,
            Self.restMeasure(), Self.restMeasure(),
        ])
        let opts = ScoreViewOptions(
            multiMeasureRest: .collapse(minimumMeasures: 2)
        )
        let doc = LayoutEngine.layout(
            score: s, options: opts, availableWidth: 1200
        )
        let hbarCounts = doc.systems.flatMap(\.measures)
            .compactMap(\.multiMeasureRest)
        // Two separate 2-measure runs, each emitted as one H-bar.
        #expect(hbarCounts == [2, 2])
    }
}
#endif
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter MultiMeasureRestLayoutTests`
Expected: PASS, all four tests.

- [ ] **Step 3: Run the full test suite to confirm no regressions**

Run: `swift test`
Expected: 100% green. Pay attention to `LayoutCacheTests`,
`MidiExportTests`, and any layout-position snapshot tests.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/MultiMeasureRestLayoutTests.swift
git commit -m "tests(layout): integration coverage for collapsed rest runs

Asserts the collapse pass emits one LayoutMeasure per run with
multiMeasureRest = runLength, preserves source measureIndex, and
that interrupting elements (rehearsal mark) split the run."
```

---

## Task 9: Add `restHBar` SMuFL glyph constant

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift`

- [ ] **Step 1: Add the constants**

In the `// Rests` group of `SMuFLGlyph`, after `restHalfLegerLine`,
add:

```swift
/// Multi-measure rest H-bar (the thick horizontal beam used in
/// part scores to compress long stretches of silence).
/// SMuFL `restHBar` (U+E4EE).
static let restHBar: Character = "\u{E4EE}"
/// Left-side cap glyph for `restHBar`. Bravura ships
/// `restHBarLeft` at U+E4EF.
static let restHBarLeft: Character = "\u{E4EF}"
/// Right-side cap glyph for `restHBar`. Bravura ships
/// `restHBarRight` at U+E4F0.
static let restHBarRight: Character = "\u{E4F0}"
```

- [ ] **Step 2: Build to confirm no typos**

Run: `swift build`
Expected: 0 errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift
git commit -m "ui: add restHBar SMuFL glyph constants"
```

---

## Task 10: Implement `MultiMeasureRestRenderer`

**Files:**
- Create: `Sources/SheetMusicUI/Rendering/MultiMeasureRestRenderer.swift`

- [ ] **Step 1: Look at MeasureRepeatRenderer for the local pattern**

Run: `cat Sources/SheetMusicUI/Rendering/MeasureRepeatRenderer.swift`

Note its `draw(...)` signature — the new renderer follows the
same conventions (CALayer-based; takes `metrics`, `height`,
`into parent`).

- [ ] **Step 2: Write the renderer**

```swift
import CoreGraphics
import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, iOS 16.0, *)
enum MultiMeasureRestRenderer {
    /// Draws a multi-measure-rest H-bar at the supplied origin
    /// (horizontal center, vertical middle of the staff) with the
    /// run's length printed above. Width comes from the layout
    /// measure (`width` parameter) so the bar fills the bar
    /// horizontally; the count is centered over the bar.
    static func draw(
        count: Int,
        origin: CGPoint,
        measureWidth: CGFloat,
        metrics: StaffMetrics,
        height _: CGFloat,
        into parent: CALayer
    ) {
        let sp = metrics.sp
        // Bar geometry: 75% of the measure width, vertically
        // centered on the middle staff line. Empirical 75%
        // matches MuseScore's default `Sid::mmRestHBarVerticalStrokeThickness`
        // proportions at typical staff sizes; tune later behind a
        // style if needed.
        let barWidth = measureWidth * 0.75
        let barLeft = origin.x - barWidth / 2
        let barCenterY = origin.y
        let bar = CALayer()
        bar.frame = CGRect(
            x: barLeft,
            y: barCenterY - sp * 0.4,
            width: barWidth,
            height: sp * 0.8
        )
        bar.backgroundColor = ScoreLayerBuilder.inkColor
        parent.addSublayer(bar)
        // End caps — short vertical strokes at each end so the
        // I-beam reads correctly.
        for side in [-1, 1] {
            let cap = CALayer()
            let xPos = side < 0 ? barLeft : barLeft + barWidth - sp * 0.2
            cap.frame = CGRect(
                x: xPos,
                y: barCenterY - sp * 1.2,
                width: sp * 0.2,
                height: sp * 2.4
            )
            cap.backgroundColor = ScoreLayerBuilder.inkColor
            parent.addSublayer(cap)
        }
        // Count text above the bar, tempo-style (bold).
        let style = ResolvedTextStyle.resolve(
            .tempo, metrics: metrics
        )
        if let text = ScoreLayerBuilder.textLayer(
            text: String(count),
            at: CGPoint(x: origin.x, y: barCenterY - sp * 2.4),
            size: style.pointSize,
            italic: false,
            anchor: CGPoint(x: 0.5, y: 0.5),
            font: style.ctFont,
            height: 0
        ) {
            parent.addSublayer(text)
        }
    }
}
```

> **Note:** the constants `ScoreLayerBuilder.inkColor` and
> `ScoreLayerBuilder.textLayer` are already used by other renderers
> in this directory — confirm their accessibility (probably
> `internal static`) and adjust if they're declared differently.
> If `textLayer` is declared `private`, lift it to `internal` and
> note the lift in the commit message.

- [ ] **Step 3: Build clean**

Run: `swift build`
Expected: 0 errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/MultiMeasureRestRenderer.swift
git commit -m "ui: render multi-measure-rest H-bar with count

Filled CALayer bar (75% of measure width) with end caps and a
tempo-style count printed above. Vertical placement centers on
the middle staff line."
```

---

## Task 11: Wire dispatch in `ScoreLayerBuilder+Element`

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift`

- [ ] **Step 1: Replace the no-op stub from Task 4**

Locate the `case .multiMeasureRest:` branch added in Task 4
(currently `break`). Replace it with the real dispatch. The
renderer needs the *measure's* width, not just the element origin
— pass it from `BuildContext` if available, otherwise add it as
a parameter to `drawElement`.

> Read the surrounding code first: `drawElement` does not currently
> receive `measureWidth`. Two options:
>
> 1. Add a `measureWidth: CGFloat` parameter to `drawElement` and
>    forward it from the caller (the per-measure draw loop).
>    Search the codebase for callers: `grep -rn drawElement(`.
> 2. Carry the width on the `LayoutElement.multiMeasureRest`
>    payload itself (extend the case to
>    `case multiMeasureRest(count: Int, origin: CGPoint, width: CGFloat)`)
>    so the renderer reads it locally without changing
>    `drawElement`.
>
> Prefer option 2 — fewer call sites change, the element is
> self-contained, and the runtime cost is one extra `CGFloat` per
> H-bar (negligible).

If you take option 2:

- Update `LayoutElement.multiMeasureRest` to include `width: CGFloat`.
- Update `makeMultiMeasureRestMeasure` (Task 7) to pass `width: width`
  when building the element.
- Update the planner integration tests (Task 8 step 1) — change
  the `compactMap` pattern to bind the new `width` field with `_`:
  `if case let .multiMeasureRest(n, _, _) = $0 { return n }`.

- [ ] **Step 2: Wire the dispatch**

```swift
case let .multiMeasureRest(count, p, width):
    MultiMeasureRestRenderer.draw(
        count: count,
        origin: shift(p),
        measureWidth: width,
        metrics: metrics,
        height: height,
        into: parent
    )
```

- [ ] **Step 3: Run tests to confirm everything still compiles**

Run: `swift test`
Expected: 100% green. The `LayoutElement` payload widening will
break the `compactMap` pattern in
`MultiMeasureRestLayoutTests.collapsedMeasureCarriesElement`; fix it
in place.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutElement.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift \
        Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift \
        Tests/SheetMusicTests/MultiMeasureRestLayoutTests.swift
git commit -m "ui: dispatch multiMeasureRest element to its renderer

LayoutElement.multiMeasureRest gains a width payload so the
renderer can size the H-bar without threading measure width
through drawElement's signature."
```

---

## Task 12: RenderPreviews sample + visual verification

**Files:**
- Modify: `Sources/RenderPreviews/Samples.swift`
- Modify: `Sources/RenderPreviews/main.swift`

- [ ] **Step 1: Read the existing samples for style reference**

Run: `head -80 Sources/RenderPreviews/Samples.swift`

Identify the pattern (a `static var name: Score` factory).

- [ ] **Step 2: Add a `multiMeasureRest` sample**

Append to `Samples.swift`:

```swift
@available(macOS 15.0, *)
static var multiMeasureRest: Score {
    let n = Note(pitch: 60, tpc: 14)
    let sounding = Measure(voices: [Voice(elements: [
        .chord(Chord(duration: .whole, notes: [n])),
    ])])
    let rest = Measure(voices: [Voice(elements: [
        .rest(duration: .whole),
    ])])
    return Score(
        division: 480,
        parts: [Part(
            id: "1",
            instrument: Instrument(id: "Piano"),
            staves: [Staff(measures: [
                sounding,
                rest, rest, rest, rest, rest, rest, rest, rest,
                sounding,
            ])]
        )]
    )
}
```

- [ ] **Step 3: Register the sample for rendering**

In `Sources/RenderPreviews/main.swift`, append an entry to the
`samples` array (right after the last entry and before the
closing `]`):

```swift
("NN-multi-measure-rest", Samples.multiMeasureRest),
```

(Replace `NN` with the next free 2-digit prefix — list the
existing entries first.)

- [ ] **Step 4: Render the preview**

Run: `swift run render-previews tmp/previews`
Expected: a new PNG `tmp/previews/NN-multi-measure-rest.png`. The
default options use `.disabled`, so this baseline shows 8
individual whole-rest bars.

- [ ] **Step 5: Add a second variant with the policy enabled**

Edit `Samples.swift`'s renderer entry once (or add a sibling
sample factory that customizes options). Since `Samples.swift`
returns `Score` only, the cleanest path is to extend
`main.swift`: introduce a parallel array of
`(name, score, options)` triples and render both
`(name, score, default)` and `(name + "-mm", score, mmOptions)`
for samples that opt in. Concretely:

```swift
let mmOptions = ScoreViewOptions(
    multiMeasureRest: .collapse(minimumMeasures: 2)
)
let extras: [(name: String, score: Score, opts: ScoreViewOptions)] = [
    ("NN-multi-measure-rest-collapsed",
     Samples.multiMeasureRest, mmOptions),
]
```

…then render both arrays into the output dir.

- [ ] **Step 6: Open the PNGs in Preview and verify visually**

```bash
open tmp/previews/NN-multi-measure-rest.png
open tmp/previews/NN-multi-measure-rest-collapsed.png
```

Expected:
- The disabled baseline shows 10 measures, 8 whole rests in a row.
- The collapsed variant shows 3 measures: sounding · H-bar with "8"
  above · sounding.

> If the collapsed bar's vertical placement is off, retune
> `barCenterY` / cap dimensions in `MultiMeasureRestRenderer`.
> Defer width tuning until both ends look right.

- [ ] **Step 7: Commit**

```bash
git add Sources/RenderPreviews/Samples.swift \
        Sources/RenderPreviews/main.swift
git commit -m "previews: add multi-measure-rest sample

Two PNGs: baseline (every rest measure visible) and collapsed
(single H-bar with count). Useful for eyeballing the renderer
during future tuning passes."
```

---

## Task 13: Final verification (build, test, lint, README touch)

**Files:** none new; sweep + commit.

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: 100% green; no skipped suites except those that were
already skipped before this change.

- [ ] **Step 2: Lint**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings, 0 errors.

- [ ] **Step 3: Confirm clean working tree**

Run: `git status`
Expected: clean (or only the README touch from step 4 below).

- [ ] **Step 4: README mention (optional)**

If the project README or `docs/musescore-engraving-reference.md`
documents `ScoreViewOptions` knobs, append a one-line entry for
`multiMeasureRest`:

```markdown
- `multiMeasureRest`: collapse runs of consecutive rest measures
  into a single H-bar. Default `.disabled`. Pass
  `.collapse(minimumMeasures: 2)` to enable.
```

(Skip this step if the file does not enumerate options today.)

- [ ] **Step 5: Final commit (only if step 4 ran)**

```bash
git add README.md docs/musescore-engraving-reference.md
git commit -m "docs: document multiMeasureRest ScoreViewOptions field"
```

- [ ] **Step 6: Summary**

The branch should now contain ~10 commits, each independently
buildable. `swift test` and `swiftlint` both green. Default
behavior (`.disabled`) unchanged.

---

## Self-review notes

- **Spec coverage:** every spec section maps to at least one task.
  - §"Public API" → Task 1
  - §"Run-break rules" → Tasks 2, 3 (each rule a test case)
  - §"Architecture / Layout integration" → Tasks 4–7
  - §"Rendering" → Tasks 9–11
  - §"Testing" → Tasks 2, 8, 12
  - §"Migration / compatibility" → Task 1's default + Task 5/6/7
    leaving `LayoutCacheTests` green.
- **Type consistency:** `MultiMeasureRestPlan` /
  `MultiMeasureRestPlanner.plan(for:policy:)` is the same name
  across Tasks 2, 3, 5, 6, 7. `LayoutElement.multiMeasureRest`
  carries `(count, origin, width)` after Task 11; tests in Task 8
  account for that revision in Task 11 step 3.
- **Width on the element:** Task 11 introduces a `width` payload
  on `.multiMeasureRest`. Earlier tasks reference the
  `.multiMeasureRest(count:, origin:)` shape; Task 11 step 3 calls
  out the test and emission edits required.
- **Cache discipline:** Task 6's cache mutation is the only
  cross-cutting concern. Disabled policy is a no-op (planner
  returns empty plan, all overrides return baseline), so cached
  scores authored before this change continue to hit.
