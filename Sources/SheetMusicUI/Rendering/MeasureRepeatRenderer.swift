import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum MeasureRepeatRenderer {
    /// Draw the standard SMuFL measure-repeat symbol (1, 2, or 4 bars).
    /// Unknown counts fall back to the 1-bar symbol.
    static func draw(
        context: inout GraphicsContext,
        count: Int,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        let codepoint = MeasureRepeatGlyph.codepoint(forCount: count)
        // swiftlint:disable:next force_unwrapping
        let glyph = Character(UnicodeScalar(codepoint)!)
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize,
        )
    }
}
