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
    /// A gradual tempo line as layers: the label's runs and the end label's filled, then the dashed line stroked
    /// (`SpannerGeometry.gradualTempoChange`).
    static func drawGradualTempoChange(
        from: CGPoint, to: CGPoint, richText: LayoutRichText?, endRichText: LayoutRichText?, metrics: StaffMetrics,
        height: CGFloat, into parent: CALayer,
    ) {
        let parts = SpannerGeometry.gradualTempoChange(
            from: from, to: to, label: richText, endLabel: endRichText, sp: metrics.sp,
        )
        let anchor = LayoutRichText.anchor(for: .gradualTempoChangeLabel)
        if let richText, let layer = richTextLayer(
            richText, at: parts.labelOrigin, anchor: anchor, color: inkColor, height: height,
        ) {
            parent.addSublayer(layer)
        }
        if let endRichText, let origin = parts.endLabelOrigin, let layer = richTextLayer(
            endRichText, at: origin, anchor: anchor, color: inkColor, height: height,
        ) {
            parent.addSublayer(layer)
        }
        guard parts.lineEnd.x > parts.lineStart.x else { return }
        let path = CGMutablePath()
        path.move(to: parts.lineStart)
        path.addLine(to: parts.lineEnd)
        let line = strokeLayer(
            path: path, height: height, lineWidth: parts.lineThickness,
            dashPattern: parts.dashPattern.map { NSNumber(value: Double($0)) },
        )
        // Flat caps, MuseScore's `PenCapStyle::FlatCap` for text lines (`tdraw.cpp:1777`).
        line.lineCap = .butt
        parent.addSublayer(line)
    }
}
