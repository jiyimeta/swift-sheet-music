import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum BreathRenderer {
    /// Draw a breath mark or caesura. `kind` selects the SMuFL glyph
    /// via `BreathGlyph.codepoint(forKind:)`. Anchor is `.center`
    /// (the convention shared with fermata / articulation glyphs).
    static func draw(
        context: inout GraphicsContext,
        kind: Breath.Kind,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        let codepoint = BreathGlyph.codepoint(forKind: kind)
        // swiftlint:disable:next force_unwrapping
        let glyph = Character(UnicodeScalar(codepoint)!)
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize,
        )
    }
}
