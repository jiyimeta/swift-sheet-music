import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum MarkerRenderer {
    static func draw(
        context: inout GraphicsContext,
        kind: Marker.Kind,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        switch kind {
        case .segno, .varsegno:
            context.drawGlyph(
                SMuFLGlyph.segno, at: origin,
                size: metrics.glyphFontSize)
        case .coda, .varcoda, .codetta, .toCodaSym:
            context.drawGlyph(
                SMuFLGlyph.coda, at: origin,
                size: metrics.glyphFontSize)
        case .fine, .toCoda, .daCapo, .dalSegno, .other:
            let label = text.isEmpty ? fallbackLabel(for: kind) : text
            context.drawExpressionText(
                label, at: origin,
                size: metrics.sp * 2.5, italic: false)
        }
    }

    private static func fallbackLabel(for kind: Marker.Kind) -> String {
        switch kind {
        case .fine: return "Fine"
        case .toCoda: return "To Coda"
        case .daCapo: return "D.C."
        case .dalSegno: return "D.S."
        case .other: return ""
        default: return ""
        }
    }
}
