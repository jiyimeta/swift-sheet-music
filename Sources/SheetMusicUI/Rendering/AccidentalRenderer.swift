import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
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
        // Glyph table is shared with the Android bridge via
        // `AccidentalGlyph` so the two platforms can't disagree.
        // swiftlint:disable:next force_unwrapping
        Character(UnicodeScalar(AccidentalGlyph.codepoint(a))!)
    }
}
