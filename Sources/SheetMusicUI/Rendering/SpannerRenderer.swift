import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum SpannerRenderer {
    static func draw(
        context: inout GraphicsContext,
        kind: LayoutElement.SpannerKind,
        from: CGPoint,
        to: CGPoint,
        continuesLeft: Bool,
        continuesRight: Bool,
        text: String,
        metrics: StaffMetrics
    ) {
        switch kind {
        case .slur:
            drawSlur(context: &context, from: from, to: to, metrics: metrics)
        case let .volta(endings):
            drawVolta(
                context: &context, from: from, to: to,
                endings: endings,
                continuesLeft: continuesLeft,
                continuesRight: continuesRight,
                metrics: metrics
            )
        case .hairpinOpen, .hairpinClose:
            drawHairpin(
                context: &context, from: from, to: to,
                open: kind == .hairpinOpen, metrics: metrics
            )
        case .pedal:
            drawPedal(
                context: &context, from: from, to: to, metrics: metrics
            )
        case .ottava:
            drawOttava(
                context: &context, from: from, to: to,
                metrics: metrics
            )
        case .textLine:
            drawTextLine(
                context: &context, from: from, to: to,
                text: text, metrics: metrics
            )
        }
    }

    private static func drawSlur(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        metrics: StaffMetrics
    ) {
        let mid = CGPoint(
            x: (from.x + to.x) / 2,
            y: min(from.y, to.y) - metrics.sp * 2
        )
        var p = Path()
        p.move(to: from)
        p.addQuadCurve(to: to, control: mid)
        context.stroke(
            p, with: .color(.primary),
            lineWidth: metrics.sp * 0.15
        )
    }

    private static func drawVolta(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        endings: [Int],
        continuesLeft: Bool, continuesRight: Bool,
        metrics: StaffMetrics
    ) {
        let top = min(from.y, to.y)
        var p = Path()
        if !continuesLeft {
            p.move(to: CGPoint(x: from.x, y: top + metrics.sp))
            p.addLine(to: CGPoint(x: from.x, y: top))
        } else {
            p.move(to: CGPoint(x: from.x, y: top))
        }
        p.addLine(to: CGPoint(x: to.x, y: top))
        if !continuesRight {
            p.addLine(to: CGPoint(x: to.x, y: top + metrics.sp))
        }
        context.stroke(
            p, with: .color(.primary),
            lineWidth: metrics.sp * 0.15
        )
        if !endings.isEmpty, !continuesLeft {
            let label = endings.map(String.init).joined(separator: ", ") + "."
            context.drawExpressionText(
                label,
                at: CGPoint(x: from.x + metrics.sp, y: top + metrics.sp / 2),
                size: metrics.sp * 2, italic: false
            )
        }
    }

    private static func drawHairpin(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        open: Bool, metrics: StaffMetrics
    ) {
        var p = Path()
        let y = max(from.y, to.y)
        if open {
            p.move(to: CGPoint(x: from.x, y: y))
            p.addLine(to: CGPoint(x: to.x, y: y - metrics.sp))
            p.move(to: CGPoint(x: from.x, y: y))
            p.addLine(to: CGPoint(x: to.x, y: y + metrics.sp))
        } else {
            p.move(to: CGPoint(x: from.x, y: y - metrics.sp))
            p.addLine(to: CGPoint(x: to.x, y: y))
            p.move(to: CGPoint(x: from.x, y: y + metrics.sp))
            p.addLine(to: CGPoint(x: to.x, y: y))
        }
        context.stroke(
            p, with: .color(.primary),
            lineWidth: metrics.sp * 0.15
        )
    }

    private static func drawPedal(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        metrics: StaffMetrics
    ) {
        context.drawExpressionText(
            "Ped.", at: from,
            size: metrics.sp * 2.5, italic: true
        )
        context.drawExpressionText(
            "*", at: to,
            size: metrics.sp * 3, italic: false
        )
    }

    private static func drawOttava(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        metrics: StaffMetrics
    ) {
        // v1 always labels "8va"; distinguishing 8vb would need the raw
        // type string threaded through. Good enough for "the marking is
        // visible".
        context.drawExpressionText(
            "8va", at: from,
            size: metrics.sp * 2.5, italic: true
        )
        var p = Path()
        p.move(to: CGPoint(x: from.x + metrics.sp * 3, y: from.y))
        p.addLine(to: to)
        context.stroke(
            p, with: .color(.primary),
            style: StrokeStyle(
                lineWidth: metrics.sp * 0.1, dash: [3, 3]
            )
        )
    }

    private static func drawTextLine(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        text: String, metrics: StaffMetrics
    ) {
        if !text.isEmpty {
            context.drawExpressionText(
                text, at: from,
                size: metrics.sp * 2.2, italic: true
            )
        }
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        context.stroke(
            p, with: .color(.primary),
            lineWidth: metrics.sp * 0.1
        )
    }
}
