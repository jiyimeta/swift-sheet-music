#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

extension RasterPage {
    /// Shortest column run emitted as a `.vertical`, in staff spaces.
    ///
    /// Below this lies notehead-interior and staff-line-crossing ink,
    /// which would otherwise emit thousands of micro-verticals per page.
    /// Above it, stems (~3.5 sp) and barlines (4.0 sp) BOTH pass —
    /// deliberately. Measured on this dataset the two populations peak at
    /// 3.0 sp (8,036 samples) and 4.0 sp (7,848) and overlap, so nothing
    /// here could separate them; and `barlineCandidates` in
    /// `PDFImporter+StaffLines.swift` already separates them using
    /// notehead abutment, which this stage does not have and P3d will
    /// supply. Duplicating that test with strictly less information would
    /// be strictly worse.
    static let verticalMinLengthInSpaces = 2.0

    /// Widest run still emitted as a `.vertical`, in staff spaces.
    ///
    /// Without this, BEAMS come out as verticals. A stack of three or
    /// four fused beams is 2.00 or 2.75 staff spaces thick — above
    /// `verticalMinLengthInSpaces` — and its columns all overlap in y, so
    /// the whole beam group would group into one blob and be emitted as a
    /// vertical the width of the beam. A real vertical is a stem
    /// (~0.15 sp wide) or a barline or bracket (up to ~0.6 sp); the
    /// narrowest beam measured on this dataset is 1.30 sp long, so 1.0 sp
    /// separates the two classes with margin on both sides.
    static let verticalMaxWidthInSpaces = 1.0

    /// Inked stretches of one column, top to bottom.
    static func columnRuns(_ mask: InkMask, x: Int) -> [(y0: Int, y1: Int)] {
        var out: [(y0: Int, y1: Int)] = []
        var start: Int?
        for y in 0 ..< mask.height {
            if mask[x, y] {
                if start == nil { start = y }
            } else if let from = start {
                out.append((from, y - 1))
                start = nil
            }
        }
        if let from = start { out.append((from, mask.height - 1)) }
        return out
    }

    /// A vertical run and the columns it spans.
    private struct VerticalBlob {
        var x0: Int
        var x1: Int
        var y0: Int
        var y1: Int
    }

    /// Column runs long enough to be a stem or a barline, grouped across
    /// adjacent columns by y-overlap into one segment each.
    ///
    /// Columns are walked left to right and runs top to bottom —
    /// raster-scan order — so the emitted order is a function of the mask
    /// alone.
    static func verticalSegments(
        _ mask: InkMask, spacingPx: Double, transform: PageTransform, pageIndex: Int,
    ) -> [PathSegment] {
        let minLengthPx = Int((verticalMinLengthInSpaces * spacingPx).rounded())
        var open: [VerticalBlob] = []
        var closed: [VerticalBlob] = []
        for x in 0 ..< mask.width {
            let runs = columnRuns(mask, x: x).filter { $0.y1 - $0.y0 + 1 >= minLengthPx }
            var next: [VerticalBlob] = []
            var consumed = [Bool](repeating: false, count: runs.count)
            for var blob in open {
                var extended = false
                for (i, run) in runs.enumerated()
                    where !consumed[i] && run.y0 <= blob.y1 && run.y1 >= blob.y0
                {
                    blob.y0 = min(blob.y0, run.y0)
                    blob.y1 = max(blob.y1, run.y1)
                    blob.x1 = x
                    consumed[i] = true
                    extended = true
                }
                if extended { next.append(blob) } else { closed.append(blob) }
            }
            for (i, run) in runs.enumerated() where !consumed[i] {
                next.append(VerticalBlob(x0: x, x1: x, y0: run.y0, y1: run.y1))
            }
            open = next
        }
        closed.append(contentsOf: open)

        let maxWidthPx = max(1, Int((verticalMaxWidthInSpaces * spacingPx).rounded()))
        return closed
            .filter { $0.x1 - $0.x0 + 1 <= maxWidthPx }
            .sorted { ($0.x0, $0.y0) < ($1.x0, $1.y0) }
            .map { segment(from: $0, transform: transform, pageIndex: pageIndex) }
    }

    private static func segment(
        from blob: VerticalBlob, transform: PageTransform, pageIndex: Int,
    ) -> PathSegment {
        let midX = Double(blob.x0 + blob.x1 + 1) / 2
        let top = transform.point(x: midX, y: Double(blob.y0))
        let bottom = transform.point(x: midX, y: Double(blob.y1 + 1))
        let widthPt = Double(blob.x1 - blob.x0 + 1) * (72.0 / transform.dpi)
        return PathSegment(
            kind: .vertical,
            rect: CGRect(
                x: top.x, y: bottom.y, width: 0, height: top.y - bottom.y,
            ),
            lineWidth: CGFloat(widthPt),
            pageIndex: pageIndex,
            quad: nil,
        )
    }
}
