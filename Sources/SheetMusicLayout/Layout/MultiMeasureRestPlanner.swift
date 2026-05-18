import SheetMusicCore

/// Plan describing how consecutive rest measures collapse into single
/// H-bar bars at layout time. Pure data; no references to layout
/// primitives.
@available(macOS 15.0, *)
public struct MultiMeasureRestPlan: Sendable, Equatable {
    /// Sorted, non-overlapping ranges of measure indices to collapse.
    /// `runs[i].lowerBound` is the bar that draws the H-bar; the
    /// remaining indices in the half-open range are skipped by
    /// `LayoutEngine`.
    public let runs: [Range<Int>]

    public init(runs: [Range<Int>] = []) {
        self.runs = runs
    }

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
@available(macOS 15.0, *)
public enum MultiMeasureRestPlanner {
    public static func plan(
        for score: Score,
        policy: MultiMeasureRestPolicy,
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
            staves: staves, measureCount: measureCount,
        )

        var runs: [Range<Int>] = []
        var runStart: Int?
        for i in 0 ..< measureCount {
            let hasSystemElement = i < score.systemMeasures.count
                && !score.systemMeasures[i].elements.isEmpty
            let collapsible = !hasSystemElement && isCollapsible(
                measureIndex: i,
                staves: staves,
                openDepthAtStart: openDepth[i],
            )
            if collapsible, runStart == nil {
                runStart = i
            }
            // An authored break on `i` (lineBreak/pageBreak) closes
            // the run *after* `i`. Determine that after this
            // measure is appended.
            let breaksAfter = anyStaffBreaksAfter(
                measureIndex: i, staves: staves,
            )
            if !collapsible {
                if let s = runStart {
                    appendIfMeetsMinimum(
                        s ..< i, into: &runs, minimum: minimum,
                    )
                    runStart = nil
                }
            } else if breaksAfter {
                if let s = runStart {
                    appendIfMeetsMinimum(
                        s ..< (i + 1), into: &runs, minimum: minimum,
                    )
                    runStart = nil
                }
            }
        }
        if let s = runStart {
            appendIfMeetsMinimum(
                s ..< measureCount, into: &runs, minimum: minimum,
            )
        }
        return MultiMeasureRestPlan(runs: runs)
    }

    // MARK: - Predicate

    /// Returns true iff every staff at `i` passes the 9-rule
    /// collapsibility check from the spec. Rule 7 (tie crossing) is
    /// structurally impossible for rest-only measures and is
    /// implicit; rule 9 (stopping at the first non-collapsible
    /// measure) is handled by the call-site loop.
    private static func isCollapsible(
        measureIndex i: Int,
        staves: [Staff],
        openDepthAtStart: Int,
    ) -> Bool {
        // Rule 6: any spanner active at the start of `i` blocks
        // collapse. Spanners that *open* in `i` are caught below by
        // the per-element scan's default branch.
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
            // Rule 1: every voice element is a rest, location shift,
            // or a *visual-only* trailing barline. A `<BarLine>` voice
            // element with a structural subtype ("start-repeat" /
            // "end-repeat") encodes a repeat boundary that must break
            // the run even when the measure-level startRepeat /
            // endRepeatCount flags are not set (MSCX permits either
            // encoding). Visual subtypes (double, final, end, dashed,
            // dotted) are preserved on the H-bar's right edge.
            // Tuplets are absent.
            for voice in m.voices {
                guard voice.tuplets.isEmpty else { return false }
                for el in voice.elements {
                    switch el {
                    case let .chord(c)
                        where c.notes.isEmpty && c.duration == .measure:
                        // MuseScore-aligned: only `.measure` rests
                        // count toward collapse. A measure padded out
                        // with several typed rests is rendered
                        // individually — even if its rests sum to the
                        // full bar.
                        continue
                    case .locationShift:
                        continue
                    case let .barLine(b):
                        if isStructuralBarLineSubtype(b.subtype) {
                            return false
                        }
                        continue
                    default:
                        return false
                    }
                }
            }
        }
        return true
    }

    /// True when a `<BarLine>` voice-element subtype encodes a
    /// repeat boundary. MSCX expresses end / start repeats either
    /// via measure-level flags (`<startRepeat/>` / `<endRepeat>N`)
    /// or via voice-level `<BarLine subtype="start-repeat">` /
    /// `"end-repeat">`. The collapsibility predicate must reject
    /// both encodings.
    private static func isStructuralBarLineSubtype(
        _ subtype: String?,
    ) -> Bool {
        switch subtype {
        case "start-repeat", "end-repeat": true
        default: false
        }
    }

    /// True when any staff at `i` has an authored lineBreak or
    /// pageBreak, which closes the current run after this measure
    /// (spec rule 8).
    private static func anyStaffBreaksAfter(
        measureIndex i: Int, staves: [Staff],
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
        minimum: Int,
    ) {
        if range.count >= minimum { runs.append(range) }
    }

    // MARK: - Spanner depth

    /// `result[i]` is the count of spanners that began at measure
    /// `j < i` and remain open at the start of `i`.
    ///
    /// A spanner with `nextMeasuresOffset = k` started at measure `j`
    /// covers measures `j..<(j+k)` — that is `k` measures total —
    /// and closes before measure `j+k`. The sweep-line decrements at
    /// `close = j + k` so depth at every interior index is correct.
    ///
    /// Mirrors the MuseScore convention verified by
    /// `openSpannerBlocksCollapse`: `nextMeasuresOffset: 4` at m0
    /// blocks m0..m3 and clears at m4.
    private static func openSpannerDepth(
        staves: [Staff], measureCount: Int,
    ) -> [Int] {
        var delta = Array(repeating: 0, count: measureCount + 1)
        for staff in staves {
            for (i, m) in staff.measures.enumerated() {
                for voice in m.voices {
                    for el in voice.elements {
                        guard case let .spanner(sp) = el else { continue }
                        let span = max(0, sp.nextMeasuresOffset)
                        // +1 at open so the opening measure itself is
                        // visible as depth > 0 (the isCollapsible predicate
                        // independently rejects it via the .spanner default
                        // branch, but consistent depth makes the logic clear).
                        if i < measureCount { delta[i] += 1 }
                        // -1 at close = i + span (covers exactly `span`
                        // measures: i, i+1, … i+span-1).
                        let close = min(measureCount, i + span)
                        delta[close] -= 1
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
