import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
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
            yOffset = metrics.sp
        case .treble8va:
            glyph = SMuFLGlyph.gClef8va
            yOffset = metrics.sp
        case .treble8vb:
            glyph = SMuFLGlyph.gClef8vb
            yOffset = metrics.sp
        case .treble15ma:
            glyph = SMuFLGlyph.gClef15ma
            yOffset = metrics.sp
        case .treble15mb:
            glyph = SMuFLGlyph.gClef15mb
            yOffset = metrics.sp
        case .bass:
            glyph = SMuFLGlyph.fClef
            yOffset = -metrics.sp
        case .bass8va:
            glyph = SMuFLGlyph.fClef8va
            yOffset = -metrics.sp
        case .bass8vb:
            glyph = SMuFLGlyph.fClef8vb
            yOffset = -metrics.sp
        case .alto, .tenor:
            glyph = SMuFLGlyph.cClef
            yOffset = 0
        case .percussion:
            glyph = SMuFLGlyph.percussionClef
            yOffset = 0
        }
        context.drawGlyph(
            glyph,
            at: CGPoint(x: origin.x, y: origin.y + yOffset),
            size: metrics.glyphFontSize
        )
    }
}
