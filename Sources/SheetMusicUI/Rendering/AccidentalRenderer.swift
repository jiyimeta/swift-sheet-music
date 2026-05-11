import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum AccidentalRenderer {
    static func draw(
        context: inout GraphicsContext,
        accidental: Accidental,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        let glyph = glyphFor(accidental)
        context.drawGlyph(
            glyph,
            at: CGPoint(
                x: origin.x - metrics.sp * 1.2,
                y: origin.y,
            ),
            size: metrics.glyphFontSize,
        )
    }

    private static func glyphFor(_ a: Accidental) -> Character {
        // Accidental is an enum (see SheetMusicCore/Score/Accidental.swift).
        switch a {
        case .sharp: SMuFLGlyph.accidentalSharp
        case .flat: SMuFLGlyph.accidentalFlat
        case .natural: SMuFLGlyph.accidentalNatural
        case .doubleSharp: SMuFLGlyph.accidentalDoubleSharp
        case .doubleFlat: SMuFLGlyph.accidentalDoubleFlat
        }
    }
}
