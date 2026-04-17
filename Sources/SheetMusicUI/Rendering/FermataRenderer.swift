import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum FermataRenderer {
    /// Draw a fermata. `subtype` is MuseScore's raw subtype string
    /// ("fermataAbove", "fermataBelow", "fermataLongAbove", ...). We
    /// pick the above/below variant by prefix; unknown subtypes fall
    /// back to the standard above-fermata glyph.
    static func draw(
        context: inout GraphicsContext,
        subtype: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let below = subtype.hasPrefix("fermataBelow")
        let glyph = below
            ? SMuFLGlyph.fermataBelow
            : SMuFLGlyph.fermataAbove
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize)
    }
}
