import SheetMusicLayout
import SwiftUI

/// Draws a tie arc as a filled crescent — thin at the endpoints, thick at the middle — the one shape
/// `TieArcGeometry.crescent` gives every renderer (MuseScore's `SlurTieLayout::computeBezier`).
@available(macOS 15.0, *)
enum TieRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        above: Bool,
        metrics: StaffMetrics,
    ) {
        let crescent = TieArcGeometry.crescent(from: from, to: to, above: above, sp: metrics.sp)
        var path = Path()
        path.move(to: crescent.start)
        // Outer curve (further from notes), then the inner one back to the start.
        path.addCurve(to: crescent.end, control1: crescent.outer1, control2: crescent.outer2)
        path.addCurve(to: crescent.start, control1: crescent.inner1, control2: crescent.inner2)
        path.closeSubpath()

        context.fill(path, with: .color(.primary))
    }
}
