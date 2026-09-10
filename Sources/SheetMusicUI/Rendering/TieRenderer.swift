import SheetMusicLayout
import SwiftUI

/// Draws a tie arc as a filled crescent — thin at the endpoints, thick
/// at the middle. Mirrors MuseScore's approach in
/// `SlurTieLayout::computeBezier`: two cubic Béziers sharing start
/// and end points form a closed shape that is zero-width at the tips
/// and `midThickness × 2` wide at the shoulder.
@available(macOS 15.0, *)
enum TieRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        above: Bool,
        metrics: StaffMetrics,
    ) {
        let points = TieArcGeometry.controlPoints(
            from: from, to: to, above: above,
            heightSp: TieArcGeometry.shoulderHeightSp(tieLengthSp: abs(to.x - from.x) / metrics.sp),
            sp: metrics.sp,
        )
        let startPt = points.p0
        let endPt = points.p3
        let ctrl1 = points.p1
        let ctrl2 = points.p2
        let vertSign: CGFloat = above ? -1 : 1
        let midThickness = metrics.sp * 0.15
        let thickDy = midThickness * vertSign * -1

        // Outer curve (further from notes).
        var path = Path()
        path.move(to: startPt)
        path.addCurve(
            to: endPt,
            control1: CGPoint(x: ctrl1.x, y: ctrl1.y - thickDy),
            control2: CGPoint(x: ctrl2.x, y: ctrl2.y - thickDy),
        )
        // Inner curve (closer to notes) — returns to start.
        path.addCurve(
            to: startPt,
            control1: CGPoint(x: ctrl2.x, y: ctrl2.y + thickDy),
            control2: CGPoint(x: ctrl1.x, y: ctrl1.y + thickDy),
        )
        path.closeSubpath()

        context.fill(path, with: .color(.primary))
    }
}
