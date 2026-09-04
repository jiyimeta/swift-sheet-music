import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum BarLineRenderer {
    /// `halfHeight` is the distance from `origin.y` to each end of the
    /// stroke, carried on `LayoutElement.barLine` — half the staff's
    /// drawn height, or 2 sp on a one-line staff. Do not re-derive it
    /// from `metrics`: `metrics` describes the five-line reference
    /// staff and knows nothing about this staff's line count.
    static func draw(
        context: inout GraphicsContext,
        subtype: String?,
        origin: CGPoint,
        halfHeight: CGFloat,
        metrics: StaffMetrics,
    ) {
        let top = CGPoint(x: origin.x, y: origin.y - halfHeight)
        let bot = CGPoint(x: origin.x, y: origin.y + halfHeight)
        let sp = metrics.sp
        let thin = sp * BarLineGeometry.thinThicknessSp
        let thick = sp * BarLineGeometry.thickThicknessSp
        func line(dx: CGFloat, width: CGFloat) {
            var p = Path()
            p.move(to: CGPoint(x: top.x + dx, y: top.y))
            p.addLine(to: CGPoint(x: bot.x + dx, y: bot.y))
            context.stroke(p, with: .color(.primary), lineWidth: width)
        }
        switch subtype {
        case "double":
            line(dx: -sp * BarLineGeometry.doubleStrokeDxSp, width: thin)
            line(dx: sp * BarLineGeometry.doubleStrokeDxSp, width: thin)
        case "end", "final":
            line(dx: 0, width: thin)
            line(dx: sp * BarLineGeometry.endThickStrokeDxSp, width: thick)
        case "start-repeat":
            line(dx: 0, width: thick)
            line(dx: sp * BarLineGeometry.repeatSecondStrokeDxSp, width: thin)
            drawRepeatDots(
                context: &context,
                origin: origin,
                xOffset: sp * BarLineGeometry.repeatDotDxSp,
                metrics: metrics,
            )
        case "end-repeat":
            drawRepeatDots(
                context: &context,
                origin: origin,
                xOffset: -sp * BarLineGeometry.repeatDotDxSp,
                metrics: metrics,
            )
            line(dx: 0, width: thin)
            line(dx: sp * BarLineGeometry.repeatSecondStrokeDxSp, width: thick)
        default:
            line(dx: 0, width: thin)
        }
    }

    /// Distance from the barline `origin.x` to the right edge of the
    /// rightmost stroke this subtype paints. Forwards to the shared
    /// engraving helper so both the staff renderer and the Android
    /// bridge consult the same numbers.
    static func rightExtent(subtype: String?, sp: CGFloat) -> CGFloat {
        BarLineGeometry.rightExtent(subtype: subtype, sp: sp)
    }

    private static func drawRepeatDots(
        context: inout GraphicsContext,
        origin: CGPoint,
        xOffset: CGFloat,
        metrics: StaffMetrics,
    ) {
        let dotSize = metrics.sp * BarLineGeometry.repeatDotDiameterSp
        context.fill(
            Path(ellipseIn: CGRect(
                x: origin.x + xOffset - dotSize / 2,
                y: origin.y - metrics.sp / 2 - dotSize / 2,
                width: dotSize, height: dotSize,
            )),
            with: .color(.primary),
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: origin.x + xOffset - dotSize / 2,
                y: origin.y + metrics.sp / 2 - dotSize / 2,
                width: dotSize, height: dotSize,
            )),
            with: .color(.primary),
        )
    }
}
