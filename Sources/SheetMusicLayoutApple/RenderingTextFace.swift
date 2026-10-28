import CoreText
import SheetMusicLayout

/// The face the Apple renderers draw a text in, when the current `FontMetrics.provider` measures it as another face.
///
/// A layout measures every text in the provider's `renderingTextFont` answer. Under CoreText that is the font asked
/// for, and the renderers draw what they always drew. A table provider carries no system face and no author face, so it
/// answers Edwin for every text face but Bravura. A layout made under such a provider — scoped with
/// `FontMetrics.withProvider` or installed process-wide — is therefore measured in Edwin, and each text site asks this
/// before choosing its font, so that the layout is drawn in the face it was measured in rather than in the system face
/// or the author's. It reads whichever provider is current at the draw, so a draw must happen where the layout's
/// provider is current.
@available(macOS 15.0, *)
package enum RenderingTextFace {
    /// The font the current `FontMetrics.provider` draws `font` in, when that differs from `font`; nil when it draws
    /// `font` as asked — always, under CoreText. A table provider answers Edwin (Bravura stays Bravura).
    package static func substitute(for font: LayoutFont) -> LayoutFont? {
        let drawn = FontMetrics.provider.renderingTextFont(font)
        return drawn == font ? nil : drawn
    }

    /// CoreText font for a substituted font, resolved as the metrics provider resolves it: an empty face is the system
    /// face, bold and italic become traits of the named family.
    package static func ctFont(_ font: LayoutFont) -> CTFont {
        AppleFontMetricsProvider().renderingFont(for: font)
    }
}
