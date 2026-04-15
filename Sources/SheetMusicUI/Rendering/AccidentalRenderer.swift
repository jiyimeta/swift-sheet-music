#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
enum AccidentalRenderer {
    static func draw(
        context: inout GraphicsContext,
        accidental: Accidental,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let glyph = glyphFor(accidental)
        context.drawGlyph(
            glyph,
            at: CGPoint(
                x: origin.x - metrics.sp * 1.2,
                y: origin.y
            ),
            size: metrics.glyphFontSize
        )
    }

    private static func glyphFor(_ a: Accidental) -> Character {
        // Accidental is an enum (see SheetMusicCore/Score/Accidental.swift).
        switch a {
        case .sharp:       return SMuFLGlyph.accidentalSharp
        case .flat:        return SMuFLGlyph.accidentalFlat
        case .natural:     return SMuFLGlyph.accidentalNatural
        case .doubleSharp: return SMuFLGlyph.accidentalDoubleSharp
        case .doubleFlat:  return SMuFLGlyph.accidentalDoubleFlat
        }
    }
}
#endif
