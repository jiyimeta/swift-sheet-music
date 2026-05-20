import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum FermataRenderer {
    /// Draw a fermata. `subtype` is MuseScore's raw subtype string
    /// ("fermataAbove", "fermataBelow", "fermataLongAbove", ...). We
    /// pick the above/below variant by prefix; unknown subtypes fall
    /// back to the standard above-fermata glyph.
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
