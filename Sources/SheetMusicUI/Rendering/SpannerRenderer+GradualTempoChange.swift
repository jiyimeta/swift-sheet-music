import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
extension SpannerRenderer {
    /// A gradual tempo line on the Canvas: the label's runs, then the dashed line
    /// (`SpannerGeometry.gradualTempoChange`).
    static func drawGradualTempoChange(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint, richText: LayoutRichText?, metrics: StaffMetrics,
    ) {
        let parts = SpannerGeometry.gradualTempoChange(from: from, to: to, label: richText, sp: metrics.sp)
        if let richText {
            TextInkRenderer.drawRich(
                context: &context, richText: richText, origin: parts.labelOrigin,
                anchor: LayoutRichText.anchor(for: .gradualTempoChangeLabel), color: .primary,
            )
        }
        guard parts.lineEnd.x > parts.lineStart.x else { return }
        var path = Path()
        path.move(to: parts.lineStart)
        path.addLine(to: parts.lineEnd)
        context.stroke(
            path, with: .color(.primary),
            style: StrokeStyle(lineWidth: parts.lineThickness, dash: parts.dashPattern),
        )
    }
}
