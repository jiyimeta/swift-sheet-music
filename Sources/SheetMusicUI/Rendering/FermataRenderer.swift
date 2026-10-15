import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum FermataRenderer {
    /// Draw a fermata. `subtype` is MuseScore's raw subtype string ("fermataAbove", "fermataBelow",
    /// "fermataLongAbove", ...); each of the fourteen draws its own glyph (`FermataGlyph.codepoint(forSubtype:)`), and
    /// an unknown subtype falls back to the standard above-fermata glyph.
    static func draw(
        context: inout GraphicsContext,
        subtype: String,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        let codepoint = FermataGlyph.codepoint(forSubtype: subtype)
        // swiftlint:disable:next force_unwrapping
        let glyph = Character(UnicodeScalar(codepoint)!)
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize,
        )
    }
}
