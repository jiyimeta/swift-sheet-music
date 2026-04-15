#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
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
            drawRepeatDots(context: &context, origin: origin,
                           xOffset: metrics.sp * 0.6, metrics: metrics)
        case "end-repeat":
            drawRepeatDots(context: &context, origin: origin,
                           xOffset: -metrics.sp * 0.6, metrics: metrics)
            line(dx: 0, width: metrics.sp * 0.15)
            line(dx: +metrics.sp * 0.3, width: metrics.sp * 0.4)
        default:
            line(dx: 0, width: metrics.sp * 0.15)
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
                width: dotSize, height: dotSize)),
            with: .color(.primary))
        context.fill(
            Path(ellipseIn: CGRect(
                x: origin.x + xOffset - dotSize / 2,
                y: origin.y + metrics.sp / 2 - dotSize / 2,
                width: dotSize, height: dotSize)),
            with: .color(.primary))
    }
}
#endif
