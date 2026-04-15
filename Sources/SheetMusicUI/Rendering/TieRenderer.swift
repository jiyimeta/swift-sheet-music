#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum TieRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        above: Bool,
        metrics: StaffMetrics
    ) {
        let midY = above
            ? min(from.y, to.y) - metrics.sp * 1.3
            : max(from.y, to.y) + metrics.sp * 1.3
        let mid = CGPoint(x: (from.x + to.x) / 2, y: midY)
        var p = Path()
        p.move(to: from)
        p.addQuadCurve(to: to, control: mid)
        context.stroke(
            p, with: .color(.primary),
            lineWidth: metrics.sp * 0.13)
    }
}
#endif
