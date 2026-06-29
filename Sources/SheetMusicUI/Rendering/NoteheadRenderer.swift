import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum NoteheadRenderer {
    /// Pick the SMuFL glyph for a note, accounting for an optional
    /// head-type override (percussion cross, diamond, triangle, etc.),
    /// the duration (whole, half, filled), and the stem direction.
    static func glyph(
        for duration: NoteDuration,
        headType: String? = nil,
        stemUp: Bool = false,
    ) -> Character {
        let cp = NoteheadGlyph.codepoint(
            duration: duration, headType: headType, stemUp: stemUp,
        )
        // swiftlint:disable:next force_unwrapping
        return Character(UnicodeScalar(cp)!)
    }

    static func drawHead(
        context: inout GraphicsContext,
        at origin: CGPoint,
        duration: NoteDuration,
        headType: String? = nil,
        stemUp: Bool = false,
        color: Color = .primary,
        metrics: StaffMetrics,
    ) {
        context.drawGlyph(
            glyph(for: duration, headType: headType, stemUp: stemUp),
            at: origin,
            size: metrics.glyphFontSize,
            color: color,
        )
    }
}
