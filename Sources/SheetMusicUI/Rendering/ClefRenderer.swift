import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum ClefRenderer {
    static func draw(
        context: inout GraphicsContext,
        rawType: String,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        let clef = NotatedClef(rawType: rawType)
        let (codepoint, yOffsetSp) = ClefGlyph.glyph(for: clef)
        // swiftlint:disable:next force_unwrapping
        let glyph = Character(UnicodeScalar(codepoint)!)
        context.drawGlyph(
            glyph,
            at: CGPoint(x: origin.x, y: origin.y + yOffsetSp * metrics.sp),
            size: metrics.glyphFontSize,
        )
    }
}
