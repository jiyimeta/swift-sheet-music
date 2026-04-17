#if os(macOS)
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
        metrics: StaffMetrics
    ) {
        // Vertical offset so the arc clears the notehead ink.
        let headClearance = metrics.sp * 0.6
        let vertSign: CGFloat = above ? -1 : 1

        let startPt = CGPoint(
            x: from.x,
            y: from.y + headClearance * vertSign)
        let endPt = CGPoint(
            x: to.x,
            y: to.y + headClearance * vertSign)

        // Shoulder height scales with tie length (MuseScore formula:
        // minShoulderHeight + 0.3 × sp × sqrt(length - 1)).
        let tieLen = abs(endPt.x - startPt.x)
        let tieLenSp = max(tieLen / metrics.sp, 0.5)
        let shoulderH = min(
            metrics.sp * 0.4 + metrics.sp * 0.3 * sqrt(tieLenSp - 0.5),
            metrics.sp * 3)

        // Mid-thickness (half the total width at the peak). MuseScore
        // uses ~0.15 sp for normal ties.
        let midThickness = metrics.sp * 0.15

        // Control points — two cubic Bézier anchors at ≈ 20% and 80%
        // of the span, both at shoulderH above/below the baseline.
        let dx = endPt.x - startPt.x
        let dy = endPt.y - startPt.y
        let ctrl1 = CGPoint(
            x: startPt.x + dx * 0.2,
            y: startPt.y + dy * 0.2 + shoulderH * vertSign)
        let ctrl2 = CGPoint(
            x: startPt.x + dx * 0.8,
            y: startPt.y + dy * 0.8 + shoulderH * vertSign)

        // Thickness offset — perpendicular to the tie baseline.
        // For roughly-horizontal ties, vertical ±midThickness is a
        // good approximation.
        let thickDy = midThickness * vertSign * -1

        // Outer curve (further from notes).
        var path = Path()
        path.move(to: startPt)
        path.addCurve(
            to: endPt,
            control1: CGPoint(x: ctrl1.x, y: ctrl1.y - thickDy),
            control2: CGPoint(x: ctrl2.x, y: ctrl2.y - thickDy))
        // Inner curve (closer to notes) — returns to start.
        path.addCurve(
            to: startPt,
            control1: CGPoint(x: ctrl2.x, y: ctrl2.y + thickDy),
            control2: CGPoint(x: ctrl1.x, y: ctrl1.y + thickDy))
        path.closeSubpath()

        context.fill(path, with: .color(.primary))
    }
}
#endif
