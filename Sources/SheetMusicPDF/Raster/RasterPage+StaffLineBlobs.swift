#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// The blob half of the staff-line pass: how inked rows become one line,
/// and where inside that blob the LINE actually is.
///
/// Split from `RasterPage+StaffLines` because the two halves change for
/// different reasons — that file holds the measured GATES, this one holds
/// the geometry they are applied to — and together they run past the
/// file-length cap.
extension RasterPage {
    /// A run and the rows it spans.
    struct LineBlob {
        var x0: Int
        var x1: Int
        var yTop: Int
        var yBottom: Int
        /// Total run width on each row from `yTop` to `yBottom`, in raster
        /// order. Kept because the bounding box alone cannot say WHERE in
        /// the blob the line is — see `staffLineCoreRowWidthFraction`.
        var rowWidths: [Int]
        /// Each row's own left and right edge, same order. Kept for the
        /// same reason `rowWidths` is, one axis over: the box says how far
        /// the blob reaches, not how far the LINE does — see
        /// `coreSpan(of:)`.
        var rowX0: [Int]
        var rowX1: [Int]
    }

    /// Vertically adjacent runs that overlap in x become one blob.
    ///
    /// Rows are walked top to bottom and runs left to right — raster-scan
    /// order — so the output is a function of the mask alone, which the
    /// determinism contract requires and the run-twice gate checks.
    static func blobs(_ runsByRow: [[(x0: Int, x1: Int)]]) -> [LineBlob] {
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
                    // Several runs of one row can join the same blob; they
                    // are all that row's contribution, so they share its
                    // slot rather than adding one each.
                    if extended {
                        let last = blob.rowWidths.count - 1
                        blob.rowWidths[last] += run.x1 - run.x0 + 1
                        blob.rowX0[last] = min(blob.rowX0[last], run.x0)
                        blob.rowX1[last] = max(blob.rowX1[last], run.x1)
                    } else {
                        blob.yBottom = y
                        blob.rowWidths.append(run.x1 - run.x0 + 1)
                        blob.rowX0.append(run.x0)
                        blob.rowX1.append(run.x1)
                        extended = true
                    }
                    consumed[i] = true
                }
                if extended { next.append(blob) } else { closed.append(blob) }
            }
            for (i, run) in runs.enumerated() where !consumed[i] {
                next.append(LineBlob(
                    x0: run.x0, x1: run.x1, yTop: y, yBottom: y,
                    rowWidths: [run.x1 - run.x0 + 1],
                    rowX0: [run.x0], rowX1: [run.x1],
                ))
            }
            open = next
        }
        return closed + open
    }

    /// Where the LINE is inside its blob: the width-weighted centroid of
    /// the rows contiguous with the widest one that are themselves at
    /// least `staffLineCoreRowWidthFraction` of it.
    ///
    /// NOT the bounding box's midpoint, which merged ink drags off the
    /// line — see `staffLineCoreRowWidthFraction`. Weighted rather than
    /// snapped to the widest row alone so a line whose ink covers an even
    /// number of rows still reports the half-row centre between them.
    static func centerRow(_ blob: LineBlob) -> Double {
        let midpoint = Double(blob.yTop + blob.yBottom) / 2
        guard let core = coreRows(of: blob) else { return midpoint }
        var weight = 0.0
        var moment = 0.0
        for row in core {
            weight += Double(blob.rowWidths[row])
            moment += Double(blob.rowWidths[row]) * Double(blob.yTop + row)
        }
        guard weight > 0 else { return midpoint }
        return moment / weight
    }

    /// The rows of a blob that are the LINE: those contiguous with the
    /// widest row and themselves at least `staffLineCoreRowWidthFraction`
    /// of it. Indices into `rowWidths` / `rowX0` / `rowX1`.
    private static func coreRows(of blob: LineBlob) -> ClosedRange<Int>? {
        guard let widest = blob.rowWidths.max(), widest > 0,
              let peak = blob.rowWidths.firstIndex(of: widest)
        else { return nil }
        let floor = Double(widest) * staffLineCoreRowWidthFraction
        var first = peak
        while first > 0, Double(blob.rowWidths[first - 1]) >= floor {
            first -= 1
        }
        var last = peak
        while last + 1 < blob.rowWidths.count,
              Double(blob.rowWidths[last + 1]) >= floor
        {
            last += 1
        }
        return first ... last
    }

    /// How far a blob's LINE reaches horizontally: the interval every one
    /// of its core rows covers, not the union of what any row reached.
    ///
    /// The y half of this was fixed first, and the x half is the same
    /// defect on the other axis. `rowRuns` bridges gaps up to
    /// `staffLineGapToleranceInSpaces`, which a broken line needs; at a
    /// line's END there is nothing to reconnect to, so the same tolerance
    /// reaches sideways into whatever ink sits near it. Measured on
    /// v2-eval: the instrument name "Tenor" in the left margin of
    /// `tex_0017` page 0 sits 4.5pt from its staff, and on ONE raster row
    /// of the staff's middle line the letters bridge in — that row runs
    /// 2117px where the line's other two run 2006px, and the blob's box
    /// takes the longest. `detectStaves` then builds the staff's `xRange`
    /// from the union, so the staff starts 26.7pt (5.9 staff spaces) left
    /// of where it does, and the score picks up a measure that is not
    /// there. Across 572 staves exactly four are affected, and the two of
    /// them on scorable renders are the ONLY two renders the whole
    /// `truthStaffLines` bisect mode wins on (+19 / +23 durP50).
    ///
    /// A line is 2–4 raster rows thick and every one of those rows spans
    /// the same x, so the intersection costs a clean line nothing and
    /// costs one row of foreign ink everything — as long as the rows are
    /// only ever TOO LONG. On a degraded page they are also too SHORT:
    /// erosion eats a row's ends, and there the widest row is the truest
    /// one and the intersection throws away real line. `staffLineCoreSpanFloor`
    /// is the line between the two regimes.
    private static func coreSpan(of blob: LineBlob) -> (x0: Int, x1: Int) {
        let box = (x0: blob.x0, x1: blob.x1)
        guard let core = coreRows(of: blob) else { return box }
        var x0 = blob.rowX0[core.lowerBound]
        var x1 = blob.rowX1[core.lowerBound]
        for row in core {
            x0 = max(x0, blob.rowX0[row])
            x1 = min(x1, blob.rowX1[row])
        }
        guard x1 > x0,
              Double(x1 - x0 + 1) >= staffLineCoreSpanFloor * Double(blob.x1 - blob.x0 + 1)
        else { return box }
        return (x0, x1)
    }

    static func segment(
        from blob: LineBlob, transform: PageTransform, pageIndex: Int,
    ) -> PathSegment {
        let midRow = centerRow(blob)
        let span = coreSpan(of: blob)
        let left = transform.point(x: Double(span.x0), y: midRow)
        let right = transform.point(x: Double(span.x1 + 1), y: midRow)
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
