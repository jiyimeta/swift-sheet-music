#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// Quad fitting (①) for the beam-geometry layer: turn a filled beam
// parallelogram's four page-space corners into a `BeamQuad` whose top /
// bottom edges are interpolated lines. Split out of PDFImporter+BeamGroups
// for file length; the membership / grouping / level logic lives there.

extension PDFImporter {
    /// Fit a `BeamQuad` to the four page-space corners of a filled beam
    /// parallelogram. Splits the corners into a left pair and a right pair
    /// by x; within each pair the higher-y point is the top edge, the
    /// lower-y the bottom. Each edge (top / bottom) is the line through its
    /// left and right endpoints. Page coordinates (PDF origin bottom-left,
    /// y increases upward).
    static func fitBeamQuad(corners: [CGPoint], pageIndex: Int) -> BeamQuad? {
        guard corners.count == 4 else { return nil }
        let byX = corners.sorted { $0.x < $1.x }
        // Left pair = first two by x, right pair = last two. (A parallelogram
        // beam has two corners at each end.)
        let left = Array(byX[0 ... 1])
        let right = Array(byX[2 ... 3])
        let topLeft = left.max { $0.y < $1.y } ?? left[0]
        let botLeft = left.min { $0.y < $1.y } ?? left[0]
        let topRight = right.max { $0.y < $1.y } ?? right[0]
        let botRight = right.min { $0.y < $1.y } ?? right[0]
        guard let lo = corners.map(\.x).min(),
              let hi = corners.map(\.x).max(), hi > lo
        else { return nil }
        let (topSlope, topIntercept) = lineThrough(topLeft, topRight)
        let (botSlope, botIntercept) = lineThrough(botLeft, botRight)
        return BeamQuad(
            xRange: lo ... hi,
            topSlope: topSlope, topIntercept: topIntercept,
            botSlope: botSlope, botIntercept: botIntercept,
            pageIndex: pageIndex,
        )
    }

    /// Slope + intercept of the line through two points. Degenerate
    /// (coincident x) → flat line at the mean y.
    private static func lineThrough(
        _ p0: CGPoint, _ p1: CGPoint,
    ) -> (slope: CGFloat, intercept: CGFloat) {
        let dx = p1.x - p0.x
        guard abs(dx) > 0.001 else { return (0, (p0.y + p1.y) / 2) }
        let m = (p1.y - p0.y) / dx
        let b = p0.y - m * p0.x
        return (m, b)
    }
}
