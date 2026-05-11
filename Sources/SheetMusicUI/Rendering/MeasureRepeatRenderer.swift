import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum MeasureRepeatRenderer {
    /// Draw the standard SMuFL measure-repeat symbol (1, 2, or 4 bars).
    /// Unknown counts fall back to the 1-bar symbol.
    static func draw(
        context: inout GraphicsContext,
        count: Int,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        let glyph: Character
        switch count {
        case 1: glyph = SMuFLGlyph.repeat1Bar
        case 2: glyph = SMuFLGlyph.repeat2Bars
        case 4: glyph = SMuFLGlyph.repeat4Bars
        default: glyph = SMuFLGlyph.repeat1Bar
        }
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize,
        )
    }
}
