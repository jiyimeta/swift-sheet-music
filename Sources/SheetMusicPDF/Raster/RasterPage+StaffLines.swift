#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

extension RasterPage {
    /// How far apart two inked stretches of one staff line may be and
    /// still be merged, in staff spaces.
    ///
    /// MEASURED, not chosen. `Training/probes/measure_staff_ink.py` walks
    /// every truth staff line across the rasters and scores, for each
    /// candidate tolerance, whether ONE surviving piece still covers 80%
    /// of the line and clears `lineClusterWidthGate`. Over 6909 lines:
    ///
    ///     tolerance   clean     degraded
    ///     0.0 sp      0.9844    0.8369
    ///     0.5 sp      0.9844    0.9003
    ///     1.0 sp      0.9844    0.9091
    ///     2.0 sp      0.9844    0.9137
    ///     6.0 sp      0.9852    0.9223
    ///
    /// 1.0 sp costs nothing on clean input and buys 7.2 points on
    /// degraded input; past it the curve is a plateau worth under half a
    /// point, which does not pay for the extra reach into unrelated ink.
    /// Re-run that probe before changing this.
    static let staffLineGapToleranceInSpaces = 1.0

    /// Minimum width, in points, for a horizontal run to be a staff-line
    /// candidate.
    ///
    /// Points rather than staff spaces on purpose: this is the same gate
    /// the downstream vector code applies (`lineClusterWidthGate`), so
    /// emitting anything narrower would be emitting something
    /// `detectStaves` is going to discard anyway.
    static let staffLineMinWidthPt: Double = 50

    /// Least fraction of a merged run's span that must actually be inked.
    ///
    /// Without this the gap tolerance MANUFACTURES STAFF LINES. A row of
    /// ledger lines above a staff is a series of ~1.6-space marks about
    /// one note apart; each is far too short to be a staff-line candidate
    /// on its own, and the vector path leaves them as fragments that
    /// `lineClusterWidthGate` discards — but a 1.0-space gap tolerance
    /// bridges them into one run wide enough to pass. `detectStaves` then
    /// has six lines to fit a five-line window to, picks the top five,
    /// and every pitch on that staff moves by two steps.
    ///
    /// That was measured, not imagined: on `cov_accidentals` the raster
    /// staff came out as `[71.6, 76.4, 81.2, 86.2, 91.0]` against the
    /// oracle's `[76.3, 81.2, 86.0, 90.8, 95.7]` — the same window
    /// shifted up by exactly one line spacing — while measure counts,
    /// note counts and durations were all perfect.
    ///
    /// 0.75 is far below any real line and far above a bridged row of
    /// marks. Measured gap statistics put a degraded staff line's ink
    /// fraction above 0.99 (2.5 gaps per line at a 0.16-space median at
    /// 200dpi, 0.24 gaps at 2.8 spaces at 300dpi, over spans of ~100
    /// spaces), while ledger-line rows come out near 0.5.
    static let staffLineMinInkFraction = 0.75

    /// Least width, as a fraction of the widest horizontal run on the
    /// page, for a run to be a staff-line candidate.
    ///
    /// The ink-fraction gate is not enough on its own. Where notes are
    /// dense, a row of ledger lines is ~1.6-space marks about 2pt apart,
    /// so the bridged run is genuinely almost solid ink and clears any
    /// ink-fraction test. Measured on `tex_0064`: eight such rows one
    /// staff space apart, 91pt wide, between two real staves whose lines
    /// are 486–510pt wide. `detectStaves` was handed eight equally
    /// spaced lines to fit a five-line window to and produced FOUR
    /// staves where the page has three; the extra staff then takes
    /// content with it, and the score-level metrics read that as lost
    /// notes and lost measures.
    ///
    /// A local rule cannot separate these — measured, the longest
    /// unbroken stretch of a real degraded staff line has p05 = 0.075 of
    /// its span, while the ledger row reaches 0.09, so the two
    /// distributions overlap. What does separate them is CONTEXT: a
    /// staff line spans its system, and every staff line on a page is
    /// about as wide as every other. Page-relative rather than absolute
    /// so a page whose only system is short still keeps its staff.
    ///
    /// The cost is that a genuinely narrow staff — an ossia beside
    /// full-width systems — is discarded. Recorded rather than hidden.
    ///
    /// 0.20 is measured, and the window is NARROW at both ends. The
    /// ledger row this exists to reject sits at 91/500 = 0.182, so
    /// anything below that stops working; and a higher value starts
    /// discarding real staff lines. Swept on 177 renders:
    ///
    ///     fraction   pitch mean   measures exact   notes exact
    ///     (none)     44.4         119              92
    ///     0.20       46.6         130              91
    ///     0.25       46.6         124              86
    ///     0.35       46.6         117              83   (one render lost its staff entirely)
    ///
    /// Re-run the hybrid sweep before changing it; the pitch column alone
    /// does not show the damage, which is why the structural columns are
    /// recorded beside it.
    static let staffLineMinWidthFractionOfWidest = 0.20

    /// Staff-line spacing in pixels, from the row projection's peak
    /// spacing; nil when the page has no staff.
    ///
    /// Bootstrapping order matters. Every other threshold in this file is
    /// expressed in staff spaces, so spacing has to come from something
    /// that needs no threshold of its own — and a row projection needs
    /// none: measured against the labels it recovers 91-96% of staff
    /// lines by itself, which is far more than locating their spacing
    /// requires.
    static func estimateStaffSpacingPx(_ mask: InkMask) -> Double? {
        var projection = [Int](repeating: 0, count: mask.height)
        for y in 0 ..< mask.height {
            var count = 0
            for x in 0 ..< mask.width where mask[x, y] {
                count += 1
            }
            projection[y] = count
        }
        guard let peak = projection.max(), peak > 0 else { return nil }
        let centers = runCenters(projection, threshold: peak / 2)
        guard centers.count >= 2 else { return nil }

        var gaps: [Double] = []
        for i in 1 ..< centers.count {
            let gap = centers[i] - centers[i - 1]
            // Between-staff gaps are far larger than within-staff ones.
            // 40px is above every within-staff spacing measured on this
            // dataset (max 33.3px, at 400dpi) and below any gap between
            // two staves.
            if gap > 1, gap < 40 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return nil }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    private static func runCenters(_ projection: [Int], threshold: Int) -> [Double] {
        var centers: [Double] = []
        var start: Int?
        for (y, count) in projection.enumerated() {
            if count >= threshold, start == nil {
                start = y
            } else if count < threshold, let from = start {
                centers.append(Double(from + y - 1) / 2)
                start = nil
            }
        }
        if let from = start { centers.append(Double(from + projection.count - 1) / 2) }
        return centers
    }

    /// Gap-tolerant horizontal runs, merged vertically into line blobs,
    /// emitted as `.horizontal` `PathSegment`s in page space.
    ///
    /// One segment per line — a DIFFERENT granularity from the vector
    /// front-end, which emits 1 to 10 segments per line. That is
    /// admissible only because `clusterHorizontals` merges co-linear
    /// segments downstream; it is also exactly why the gap merge has to
    /// happen HERE. `detectStaves` positions lines only from segments
    /// wider than `lineClusterWidthGate` = 50pt, so a line that arrives
    /// as ten 30pt fragments is not a slightly worse line, it is a line
    /// that does not exist.
    static func staffLineSegments(
        _ mask: InkMask, spacingPx: Double, transform: PageTransform, pageIndex: Int,
    ) -> [PathSegment] {
        let gapTolerance = max(1, Int((staffLineGapToleranceInSpaces * spacingPx).rounded()))
        let minWidthPx = max(1, Int((staffLineMinWidthPt * transform.dpi / 72.0).rounded()))
        var runsByRow: [[(x0: Int, x1: Int)]] = []
        runsByRow.reserveCapacity(mask.height)
        for y in 0 ..< mask.height {
            runsByRow.append(rowRuns(
                mask, y: y, gapTolerance: gapTolerance, minWidthPx: minWidthPx,
            ))
        }
        let found = blobs(runsByRow)
        let floor = referenceWidth(found) * staffLineMinWidthFractionOfWidest
        return found
            .filter { Double($0.x1 - $0.x0 + 1) >= floor }
            .map { segment(from: $0, transform: transform, pageIndex: pageIndex) }
    }

    /// The page's "a staff line is about this wide" reference: the median
    /// width of the widest quarter of the runs.
    ///
    /// NOT the maximum. A single full-page-width run — a page border, a
    /// frame rule — becomes the maximum and lifts the floor above the
    /// real staff lines of a small-format score, which measured as nine
    /// fewer renders with exact note counts. The widest quarter is a
    /// staff's own lines on any page that has a staff at all, and one
    /// outlier cannot move its median.
    private static func referenceWidth(_ found: [LineBlob]) -> Double {
        let widths = found.map { $0.x1 - $0.x0 + 1 }.sorted(by: >)
        guard !widths.isEmpty else { return 0 }
        let top = widths.prefix(max(1, widths.count / 4))
        return Double(top[top.count / 2])
    }

    /// Inked stretches of one row, with gaps up to `gapTolerance`
    /// bridged, keeping only those at least `minWidthPx` wide AND at
    /// least `staffLineMinInkFraction` inked.
    ///
    /// The ink fraction is what separates a broken staff line from a
    /// bridged row of ledger lines — see `staffLineMinInkFraction`.
    private static func rowRuns(
        _ mask: InkMask, y: Int, gapTolerance: Int, minWidthPx: Int,
    ) -> [(x0: Int, x1: Int)] {
        var out: [(x0: Int, x1: Int)] = []
        var start: Int?
        var lastInk: Int?
        var inked = 0
        func close(_ from: Int, _ last: Int, _ ink: Int) {
            let span = last - from + 1
            guard span >= minWidthPx,
                  Double(ink) >= staffLineMinInkFraction * Double(span)
            else { return }
            out.append((from, last))
        }
        for x in 0 ..< mask.width where mask[x, y] {
            if let last = lastInk, x - last > gapTolerance, let from = start {
                close(from, last, inked)
                start = x
                inked = 0
            } else if start == nil {
                start = x
                inked = 0
            }
            lastInk = x
            inked += 1
        }
        if let from = start, let last = lastInk { close(from, last, inked) }
        return out
    }

    /// A run and the rows it spans.
    private struct LineBlob {
        var x0: Int
        var x1: Int
        var yTop: Int
        var yBottom: Int
    }

    /// Vertically adjacent runs that overlap in x become one blob.
    ///
    /// Rows are walked top to bottom and runs left to right — raster-scan
    /// order — so the output is a function of the mask alone, which the
    /// determinism contract requires and the run-twice gate checks.
    private static func blobs(_ runsByRow: [[(x0: Int, x1: Int)]]) -> [LineBlob] {
        var open: [LineBlob] = []
        var closed: [LineBlob] = []
        for (y, runs) in runsByRow.enumerated() {
            var next: [LineBlob] = []
            var consumed = [Bool](repeating: false, count: runs.count)
            for var blob in open {
                var extended = false
                for (i, run) in runs.enumerated()
                    where !consumed[i] && run.x0 <= blob.x1 && run.x1 >= blob.x0
                {
                    blob.x0 = min(blob.x0, run.x0)
                    blob.x1 = max(blob.x1, run.x1)
                    blob.yBottom = y
                    consumed[i] = true
                    extended = true
                }
                if extended { next.append(blob) } else { closed.append(blob) }
            }
            for (i, run) in runs.enumerated() where !consumed[i] {
                next.append(LineBlob(x0: run.x0, x1: run.x1, yTop: y, yBottom: y))
            }
            open = next
        }
        return closed + open
    }

    private static func segment(
        from blob: LineBlob, transform: PageTransform, pageIndex: Int,
    ) -> PathSegment {
        let midRow = Double(blob.yTop + blob.yBottom) / 2
        let left = transform.point(x: Double(blob.x0), y: midRow)
        let right = transform.point(x: Double(blob.x1 + 1), y: midRow)
        let thicknessPt = Double(blob.yBottom - blob.yTop + 1) * (72.0 / transform.dpi)
        return PathSegment(
            kind: .horizontal,
            rect: CGRect(x: left.x, y: left.y, width: right.x - left.x, height: 0),
            lineWidth: CGFloat(thicknessPt),
            pageIndex: pageIndex,
            quad: nil,
        )
    }
}
