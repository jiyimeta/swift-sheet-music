#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum StaffRenderer {
    /// Draw five horizontal staff lines. `origin` is the top-left of the
    /// top line; `width` is how far they run. The fifth (bottom) line lies
    /// at `origin.y + 4 * sp`.
    static func draw(
        context: inout GraphicsContext,
        origin: CGPoint,
        width: CGFloat,
        metrics: StaffMetrics
    ) {
        for i in 0..<5 {
            let y = origin.y + CGFloat(i) * metrics.sp
            var path = Path()
            path.move(to: CGPoint(x: origin.x, y: y))
            path.addLine(to: CGPoint(x: origin.x + width, y: y))
            context.stroke(
                path,
                with: .color(.primary),
                lineWidth: metrics.staffLineThickness
            )
        }
    }
}
#endif
