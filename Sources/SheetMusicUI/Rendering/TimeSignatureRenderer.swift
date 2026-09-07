import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum TimeSignatureRenderer {
    static func draw(
        context: inout GraphicsContext,
        numerator: Int,
        denominator: Int,
        symbol: TimeSignatureSymbol,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        // A symbol is ONE glyph on the staff middle, replacing both rows.
        if let glyph = SMuFLGlyph.timeSigSymbol(symbol) {
            context.drawGlyph(
                glyph,
                at: CGPoint(
                    x: origin.x,
                    y: origin.y + TimeSignatureLayout.symbolDy(sp: metrics.sp),
                ),
                size: metrics.glyphFontSize,
            )
            return
        }
        let advance = TimeSignatureLayout.digitAdvance(sp: metrics.sp)
        let (numOffsetX, denOffsetX, _) = TimeSignatureLayout.rowOffsets(
            numerator: numerator,
            denominator: denominator,
            sp: metrics.sp,
        )
        drawRow(
            context: &context,
            value: numerator,
            rowY: origin.y + TimeSignatureLayout.numeratorDy(sp: metrics.sp),
            rowOriginX: origin.x + numOffsetX,
            advance: advance,
            glyphFontSize: metrics.glyphFontSize,
        )
        drawRow(
            context: &context,
            value: denominator,
            rowY: origin.y + TimeSignatureLayout.denominatorDy(sp: metrics.sp),
            rowOriginX: origin.x + denOffsetX,
            advance: advance,
            glyphFontSize: metrics.glyphFontSize,
        )
    }

    private static func drawRow(
        context: inout GraphicsContext,
        value: Int,
        rowY: CGFloat,
        rowOriginX: CGFloat,
        advance: CGFloat,
        glyphFontSize: CGFloat,
    ) {
        for (i, ch) in String(value).enumerated() {
            let digit = Int(String(ch)) ?? 0
            context.drawGlyph(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(x: rowOriginX + CGFloat(i) * advance, y: rowY),
                size: glyphFontSize,
            )
        }
    }
}
