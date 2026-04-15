#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum GlissandoRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        wavy: Bool,
        text: String?,
        metrics: StaffMetrics
    ) {
        var p = Path()
        if wavy {
            // Crude 3-segment wave; replace post-v1 with proper glyph.
            let dx = (to.x - from.x) / 3
            let dy = (to.y - from.y) / 3
            p.move(to: from)
            for i in 1...3 {
                let x = from.x + dx * CGFloat(i)
                let y = from.y + dy * CGFloat(i)
                    + (i.isMultiple(of: 2)
                       ? metrics.sp * 0.3
                       : -metrics.sp * 0.3)
                p.addLine(to: CGPoint(x: x, y: y))
            }
        } else {
            p.move(to: from)
            p.addLine(to: to)
        }
        context.stroke(
            p, with: .color(.primary),
            lineWidth: metrics.sp * 0.15)
        if let text, !text.isEmpty {
            let mid = CGPoint(
                x: (from.x + to.x) / 2,
                y: (from.y + to.y) / 2 - metrics.sp)
            context.drawExpressionText(
                text, at: mid,
                size: metrics.sp * 1.8, italic: true)
        }
    }
}
#endif
