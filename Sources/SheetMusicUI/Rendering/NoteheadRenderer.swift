import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum NoteheadRenderer {
    /// Pick the SMuFL glyph for a note, accounting for an optional
    /// head-type override (percussion cross, diamond, triangle, etc.)
    /// and the duration (whole, half, filled).
    static func glyph(
        for duration: NoteDuration,
        headType: String? = nil,
    ) -> Character {
        let cp = NoteheadGlyph.codepoint(
            duration: duration, headType: headType,
        )
        // swiftlint:disable:next force_unwrapping
        return Character(UnicodeScalar(cp)!)
    }

    static func drawHead(
        context: inout GraphicsContext,
        at origin: CGPoint,
        duration: NoteDuration,
        headType: String? = nil,
        color: Color = .primary,
        metrics: StaffMetrics,
    ) {
        context.drawGlyph(
            glyph(for: duration, headType: headType),
            at: origin,
            size: metrics.glyphFontSize,
            color: color,
        )
    }
}
