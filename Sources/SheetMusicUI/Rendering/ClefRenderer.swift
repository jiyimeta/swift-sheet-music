#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum ClefRenderer {
    static func draw(
        context: inout GraphicsContext,
        rawType: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let clef = NotatedClef(rawType: rawType)
        let glyph: Character
        let yOffset: CGFloat
        switch clef {
        case .treble:
            glyph = SMuFLGlyph.gClef
            yOffset = metrics.sp     // G clef sits slightly below mid line
        case .bass:
            glyph = SMuFLGlyph.fClef
            yOffset = -metrics.sp
        case .alto, .tenor:
            glyph = SMuFLGlyph.cClef
            yOffset = 0
        }
        context.drawGlyph(
            glyph,
            at: CGPoint(x: origin.x, y: origin.y + yOffset),
            size: metrics.glyphFontSize
        )
    }
}
#endif
