import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum BarLineRenderer {
    static func draw(
        context: inout GraphicsContext,
        subtype: String?,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let top = CGPoint(x: origin.x, y: origin.y - metrics.sp * 2)
        let bot = CGPoint(x: origin.x, y: origin.y + metrics.sp * 2)
        func line(dx: CGFloat, width: CGFloat) {
            var p = Path()
            p.move(to: CGPoint(x: top.x + dx, y: top.y))
            p.addLine(to: CGPoint(x: bot.x + dx, y: bot.y))
            context.stroke(p, with: .color(.primary), lineWidth: width)
        }
        switch subtype {
        case "double":
            line(dx: -metrics.sp * 0.3, width: metrics.sp * 0.15)
            line(dx: +metrics.sp * 0.3, width: metrics.sp * 0.15)
        case "end", "final":
            line(dx: 0, width: metrics.sp * 0.15)
            line(dx: +metrics.sp * 0.4, width: metrics.sp * 0.4)
        case "start-repeat":
            line(dx: 0, width: metrics.sp * 0.4)
            line(dx: +metrics.sp * 0.3, width: metrics.sp * 0.15)
            drawRepeatDots(
                context: &context,
                origin: origin,
                xOffset: metrics.sp * 0.6,
                metrics: metrics
            )
        case "end-repeat":
            drawRepeatDots(
                context: &context,
                origin: origin,
                xOffset: -metrics.sp * 0.6,
                metrics: metrics
            )
            line(dx: 0, width: metrics.sp * 0.15)
            line(dx: +metrics.sp * 0.3, width: metrics.sp * 0.4)
        default:
            line(dx: 0, width: metrics.sp * 0.15)
        }
    }

    /// Distance from the barline `origin.x` to the right edge of the
    /// rightmost stroke this subtype paints. Used by the staff
    /// renderer to clip the five-line staff so it terminates flush
    /// with the system-end barline glyph (the staff should pass
    /// through every component of the barline pair, not stop at the
    /// thin half of an end / double / end-repeat). Mirrors the
    /// `dx + width / 2` extents inside `draw` above — keep both in
    /// sync.
    static func rightExtent(subtype: String?, sp: CGFloat) -> CGFloat {
        switch subtype {
        case "end", "final":
            // Thick stroke at dx = +0.4 sp, width 0.4 sp → right edge.
            return sp * 0.6
        case "end-repeat":
            // Thick stroke at dx = +0.3 sp, width 0.4 sp → right edge.
            return sp * 0.5
        case "double":
            // Right thin stroke at dx = +0.3 sp, width 0.15 sp.
            return sp * 0.375
        case "start-repeat":
            // Thin stroke at dx = +0.3 sp, width 0.15 sp. Repeat dots
            // sit further right but are not part of the staff line.
            return sp * 0.375
        default:
            // Single thin stroke at dx = 0, width 0.15 sp.
            return sp * 0.075
        }
    }

    private static func drawRepeatDots(
        context: inout GraphicsContext,
        origin: CGPoint,
        xOffset: CGFloat,
        metrics: StaffMetrics
    ) {
        let dotSize: CGFloat = metrics.sp * 0.3
        context.fill(
            Path(ellipseIn: CGRect(
                x: origin.x + xOffset - dotSize / 2,
                y: origin.y - metrics.sp / 2 - dotSize / 2,
                width: dotSize, height: dotSize
            )),
            with: .color(.primary)
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: origin.x + xOffset - dotSize / 2,
                y: origin.y + metrics.sp / 2 - dotSize / 2,
                width: dotSize, height: dotSize
            )),
            with: .color(.primary)
        )
    }
}
