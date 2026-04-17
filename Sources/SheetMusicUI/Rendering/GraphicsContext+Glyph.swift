import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
extension GraphicsContext {
    /// Draw a SMuFL glyph anchored at `origin` using the Bravura font.
    /// Default anchor is `.center` for notehead-like glyphs. Flags,
    /// rests, and clefs that need specific attachment points pass a
    /// different anchor (e.g. `.topLeading` so the glyph's NW sits at
    /// the stem tip).
    mutating func drawGlyph(
        _ glyph: Character,
        at origin: CGPoint,
        size: CGFloat,
        color: Color = .primary,
        anchor: UnitPoint = .center
    ) {
        let text = Text(String(glyph))
            .font(.custom(BravuraFont.familyName, size: size))
            .foregroundColor(color)
        let resolved = resolve(text)
        draw(resolved, at: origin, anchor: anchor)
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
