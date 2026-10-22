import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum MeasureRepeatRenderer {
    /// Draw the standard SMuFL measure-repeat symbol (1, 2, or 4 bars), and above a 2- or 4-bar one its number
    /// (`MeasureRepeatGlyph.numberCenter`). Unknown counts fall back to the 1-bar symbol.
    static func draw(
        context: inout GraphicsContext,
        count: Int,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        draw(codepoint: MeasureRepeatGlyph.codepoint(forCount: count), at: origin, context: &context, metrics: metrics)
        if let digit = MeasureRepeatGlyph.numberCodepoint(forCount: count),
           let center = MeasureRepeatGlyph.numberCenter(forCount: count, sp: metrics.sp)
        {
            let at = CGPoint(x: origin.x + center.x, y: origin.y + center.y)
            draw(codepoint: digit, at: at, context: &context, metrics: metrics)
        }
    }

    private static func draw(
        codepoint: UInt32, at origin: CGPoint, context: inout GraphicsContext, metrics: StaffMetrics,
    ) {
        // swiftlint:disable:next force_unwrapping
        let glyph = Character(UnicodeScalar(codepoint)!)
        context.drawGlyph(glyph, at: origin, size: metrics.glyphFontSize)
    }
}
