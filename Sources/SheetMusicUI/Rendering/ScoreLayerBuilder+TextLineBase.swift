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
    /// A text-line-family segment (pedal, text line, palm mute, let ring, the guitar lines) as layers: the begin and
    /// end labels' runs filled, then each stroke of `SpannerGeometry.textLineBase` stroked with its own dash
    /// pattern and cap: flat (MuseScore's `PenCapStyle::FlatCap`, `tdraw.cpp:1778`), round for a dotted line.
    static func drawTextLineBase(
        kind: LayoutElement.SpannerKind, from: CGPoint, to: CGPoint, richText: LayoutRichText?,
        lineDetail: LayoutLineDetail?, metrics: StaffMetrics, height: CGFloat, into parent: CALayer,
    ) {
        guard let detail = SpannerGeometry.resolvedLineDetail(kind: kind, detail: lineDetail, sp: metrics.sp) else {
            return
        }
        let parts = SpannerGeometry.textLineBase(from: from, to: to, label: richText, detail: detail, sp: metrics.sp)
        let anchor = LayoutRichText.anchor(for: .lineLabel)
        let labels = [(richText, parts.beginOrigin), (detail.endRichText, parts.endOrigin)]
        for case let (label?, origin?) in labels {
            if let layer = richTextLayer(label, at: origin, anchor: anchor, color: inkColor, height: height) {
                parent.addSublayer(layer)
            }
        }
        for stroke in parts.strokes {
            guard let first = stroke.points.first else { continue }
            let path = CGMutablePath()
            path.move(to: first)
            for point in stroke.points.dropFirst() {
                path.addLine(to: point)
            }
            let dashes = stroke.dashPattern.isEmpty ? nil : stroke.dashPattern.map { NSNumber(value: Double($0)) }
            let layer = strokeLayer(path: path, height: height, lineWidth: parts.thickness, dashPattern: dashes)
            layer.lineCap = stroke.roundCap ? .round : .butt
            parent.addSublayer(layer)
        }
    }
}
