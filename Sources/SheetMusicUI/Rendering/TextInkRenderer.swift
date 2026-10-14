import CoreText
import SheetMusicLayout
import SwiftUI

/// Canvas and CALayer share vector text outlines, including multiline and bearing anchoring.
@available(macOS 15.0, *)
enum TextInkRenderer {
    static func draw(
        context: inout GraphicsContext, text: String, font: CTFont,
        origin: CGPoint, anchor: CGPoint, color: Color,
    ) {
        guard let path = ScoreLayerBuilder.anchoredTextPath(text, font: font, origin: origin, anchor: anchor)
        else { return }
        context.fill(Path(path), with: .color(color))
    }

    /// A text element's typeset runs, filled from the same outline the CALayer tree fills
    /// (`ScoreLayerBuilder.richTextPath`).
    static func drawRich(
        context: inout GraphicsContext, richText: LayoutRichText, origin: CGPoint, anchor: CGPoint, color: Color,
    ) {
        guard let path = ScoreLayerBuilder.richTextPath(richText, origin: origin, anchor: anchor) else { return }
        context.fill(Path(path), with: .color(color))
    }
}
