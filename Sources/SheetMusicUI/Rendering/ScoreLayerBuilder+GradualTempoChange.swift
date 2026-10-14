import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    /// A gradual tempo line as layers: the label's runs filled, then the dashed line stroked
    /// (`SpannerGeometry.gradualTempoChange`).
    static func drawGradualTempoChange(
        from: CGPoint, to: CGPoint, richText: LayoutRichText?, metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let parts = SpannerGeometry.gradualTempoChange(from: from, to: to, label: richText, sp: metrics.sp)
        if let richText, let layer = richTextLayer(
            richText, at: parts.labelOrigin, anchor: LayoutRichText.anchor(for: .gradualTempoChangeLabel),
            color: inkColor, height: height,
        ) {
            parent.addSublayer(layer)
        }
        guard parts.lineEnd.x > parts.lineStart.x else { return }
        let path = CGMutablePath()
        path.move(to: parts.lineStart)
        path.addLine(to: parts.lineEnd)
        parent.addSublayer(strokeLayer(
            path: path, height: height, lineWidth: parts.lineThickness,
            dashPattern: parts.dashPattern.map { NSNumber(value: Double($0)) },
        ))
    }
}
