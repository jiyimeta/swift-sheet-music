#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
extension GraphicsContext {
    /// Draw a SMuFL glyph centered at `origin` using the Bravura font.
    mutating func drawGlyph(
        _ glyph: Character,
        at origin: CGPoint,
        size: CGFloat,
        color: Color = .primary
    ) {
        let text = Text(String(glyph))
            .font(.custom(BravuraFont.familyName, size: size))
            .foregroundColor(color)
        let resolved = resolve(text)
        draw(resolved, at: origin, anchor: .center)
    }

    /// Draw short text (dynamic markings, tempo labels).
    mutating func drawExpressionText(
        _ string: String,
        at origin: CGPoint,
        size: CGFloat,
        italic: Bool = true,
        color: Color = .primary,
        anchor: UnitPoint = .leading
    ) {
        let base = Text(string).foregroundColor(color)
        let styled = italic
            ? base.font(.system(size: size, weight: .semibold).italic())
            : base.font(.system(size: size, weight: .semibold))
        let resolved = resolve(styled)
        draw(resolved, at: origin, anchor: anchor)
    }
}
#endif
