import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
extension SpannerRenderer {
    /// A text-line-family segment on the Canvas: the begin and end labels' runs, then each stroke of
    /// `SpannerGeometry.textLineBase` with its own dash pattern and cap: flat (MuseScore's
    /// `PenCapStyle::FlatCap`, `tdraw.cpp:1778`), round for a dotted line.
    static func drawTextLineBase(
        context: inout GraphicsContext, kind: LayoutElement.SpannerKind, from: CGPoint, to: CGPoint,
        richText: LayoutRichText?, lineDetail: LayoutLineDetail?, metrics: StaffMetrics,
    ) {
        guard let detail = SpannerGeometry.resolvedLineDetail(kind: kind, detail: lineDetail, sp: metrics.sp) else {
            return
        }
        let parts = SpannerGeometry.textLineBase(from: from, to: to, label: richText, detail: detail, sp: metrics.sp)
        let anchor = LayoutRichText.anchor(for: .lineLabel)
        let labels = [(richText, parts.beginOrigin), (detail.endRichText, parts.endOrigin)]
        for case let (label?, origin?) in labels {
            TextInkRenderer.drawRich(
                context: &context, richText: label, origin: origin, anchor: anchor, color: .primary,
            )
        }
        for stroke in parts.strokes {
            guard let first = stroke.points.first else { continue }
            var path = Path()
            path.move(to: first)
            for point in stroke.points.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(
                path, with: .color(.primary),
                style: StrokeStyle(
                    lineWidth: parts.thickness, lineCap: stroke.roundCap ? .round : .butt, dash: stroke.dashPattern,
                ),
            )
        }
    }
}
