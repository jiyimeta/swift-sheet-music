import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum RestRenderer {
    static func draw(
        context: inout GraphicsContext,
        duration: NoteDuration,
        hasLegerLine: Bool = false,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        let codepoint = RestGlyph.codepoint(
            duration: duration, hasLegerLine: hasLegerLine,
        )
        // swiftlint:disable:next force_unwrapping
        let glyph = Character(UnicodeScalar(codepoint)!)
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize,
        )
    }
}
