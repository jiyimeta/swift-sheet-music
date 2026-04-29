import SwiftUI
import SheetMusicLayout

@available(macOS 15.0, iOS 16.0, *)
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

    /// Draw a bracket linking the tops of multiple staves (piano grand
    /// staff etc.). v1 draws a thick vertical line with short horizontal
    /// serifs at top and bottom — good enough to visually group staves.
    static func drawBracket(
        context: inout GraphicsContext,
        top: CGPoint,
        bottom: CGPoint,
        metrics: StaffMetrics
    ) {
        var spine = Path()
        spine.move(to: top)
        spine.addLine(to: CGPoint(x: top.x, y: bottom.y))
        context.stroke(
            spine, with: .color(.primary),
            lineWidth: metrics.sp * 0.3)
        for point in [top, bottom] {
            var serif = Path()
            serif.move(to: point)
            serif.addLine(to: CGPoint(
                x: point.x + metrics.sp * 0.8, y: point.y))
            context.stroke(
                serif, with: .color(.primary),
                lineWidth: metrics.sp * 0.25)
        }
    }
}
