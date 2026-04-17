import SheetMusicCore
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum RestRenderer {
    static func draw(
        context: inout GraphicsContext,
        duration: NoteDuration,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let glyph: Character
        switch duration {
        case .whole: glyph = SMuFLGlyph.restWhole
        case .half: glyph = SMuFLGlyph.restHalf
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
