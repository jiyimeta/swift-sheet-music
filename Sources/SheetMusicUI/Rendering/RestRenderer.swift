import SheetMusicCore
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum RestRenderer {
    static func draw(
        context: inout GraphicsContext,
        duration: NoteDuration,
        hasLegerLine: Bool = false,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let glyph: Character
        switch duration {
        case .whole:
            glyph = hasLegerLine
                ? SMuFLGlyph.restWholeLegerLine
                : SMuFLGlyph.restWhole
        case .half:
            glyph = hasLegerLine
                ? SMuFLGlyph.restHalfLegerLine
                : SMuFLGlyph.restHalf
        case .quarter: glyph = SMuFLGlyph.restQuarter
        case .eighth: glyph = SMuFLGlyph.rest8th
        case .sixteenth: glyph = SMuFLGlyph.rest16th
        case .thirtySecond: glyph = SMuFLGlyph.rest32nd
        case .sixtyFourth: glyph = SMuFLGlyph.rest64th
        default: glyph = SMuFLGlyph.restQuarter
        }
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize)
    }
}
