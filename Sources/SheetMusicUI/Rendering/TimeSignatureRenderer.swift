import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum TimeSignatureRenderer {
    static func draw(
        context: inout GraphicsContext,
        numerator: Int,
        denominator: Int,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        let numStr = String(numerator)
        let denStr = String(denominator)
        // Bravura time-sig digits are ~1.3 sp wide at glyphFontSize.
        // Advance by 1.4 sp per digit so multi-digit numbers (12, 15)
        // don't overlap.
        let digitAdvance = metrics.sp * 1.4
        let numWidth = CGFloat(numStr.count) * digitAdvance
        let denWidth = CGFloat(denStr.count) * digitAdvance
        let maxWidth = max(numWidth, denWidth)

        // Centre each row horizontally so "12" and "8" are both
        // centred on the same vertical axis.
        let numOffsetX = (maxWidth - numWidth) / 2
        let denOffsetX = (maxWidth - denWidth) / 2

        for (i, ch) in numStr.enumerated() {
            let digit = Int(String(ch)) ?? 0
            context.drawGlyph(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(
                    x: origin.x + numOffsetX + CGFloat(i) * digitAdvance,
                    y: origin.y - metrics.sp,
                ),
                size: metrics.glyphFontSize,
            )
        }
        for (i, ch) in denStr.enumerated() {
            let digit = Int(String(ch)) ?? 0
            context.drawGlyph(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(
                    x: origin.x + denOffsetX + CGFloat(i) * digitAdvance,
                    y: origin.y + metrics.sp,
                ),
                size: metrics.glyphFontSize,
            )
        }
    }
}
