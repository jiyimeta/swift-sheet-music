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
    /// end labels' runs filled, then each stroke of `SpannerGeometry.textLineBase` stroked with flat caps
    /// (MuseScore's `PenCapStyle::FlatCap`, `tdraw.cpp:1778`) and the style's dash pattern.
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
        let dashes = parts.dashPattern.isEmpty ? nil : parts.dashPattern.map { NSNumber(value: Double($0)) }
        for stroke in parts.strokes {
            guard let first = stroke.first else { continue }
            let path = CGMutablePath()
            path.move(to: first)
            for point in stroke.dropFirst() {
                path.addLine(to: point)
            }
            let layer = strokeLayer(path: path, height: height, lineWidth: parts.thickness, dashPattern: dashes)
            layer.lineCap = .butt
            parent.addSublayer(layer)
        }
    }
}
