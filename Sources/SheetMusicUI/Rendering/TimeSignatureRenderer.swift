#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum TimeSignatureRenderer {
    static func draw(
        context: inout GraphicsContext,
        numerator: Int,
        denominator: Int,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let numStr = String(numerator)
        let denStr = String(denominator)
        let digitAdvance = metrics.sp
        for (i, ch) in numStr.enumerated() {
            let digit = Int(String(ch)) ?? 0
            context.drawGlyph(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(
                    x: origin.x + CGFloat(i) * digitAdvance,
                    y: origin.y - metrics.sp
                ),
                size: metrics.glyphFontSize
            )
        }
        for (i, ch) in denStr.enumerated() {
            let digit = Int(String(ch)) ?? 0
            context.drawGlyph(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(
                    x: origin.x + CGFloat(i) * digitAdvance,
                    y: origin.y + metrics.sp
                ),
                size: metrics.glyphFontSize
            )
        }
    }
}
#endif
