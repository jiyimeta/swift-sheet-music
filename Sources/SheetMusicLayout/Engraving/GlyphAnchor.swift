#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Offset that converts a SMuFL glyph emitted with SwiftUI's `.center`
/// anchor into a baseline-leading anchor (the position
/// `Canvas.drawText` on Android takes).
///
/// `LayoutEngine` emits glyph origins assuming Apple's
/// `context.draw(resolved, at:, anchor: .center)` semantics. SwiftUI
/// centres the **typographic frame** (advance × line-height built from
/// the font's ascent/descent) on the anchor point — NOT the ink-path
/// bbox. For Bravura specifically, `CTFontGetAscent` and
/// `CTFontGetDescent` are symmetric (≈ 2 em each), so the typographic
/// frame's vertical centre coincides with the baseline:
///
///     leading.x  = center.x - advance / 2
///     baseline.y = center.y   // Bravura: (ascent − descent) / 2 == 0
///
/// Verified empirically against `CTFontGetAscent(Bravura@20pt)` and
/// `CTFontGetDescent(Bravura@20pt)` (both = 40.24 pt). The earlier
/// bbox-midY variant of this helper over-shifted every glyph by its
/// own `bbox.midY` — most visibly the treble clef (1 sp drift).
public enum GlyphAnchor {
    /// `(dx, dy)` to add to a `.center`-anchor `(x, y)` to obtain the
    /// baseline-leading position. Uses the glyph's advance for X;
    /// Y stays at 0 for Bravura SMuFL glyphs.
    public static func centerToBaselineLeading(
        advance: CGFloat,
    ) -> (dx: CGFloat, dy: CGFloat) {
        (dx: -advance / 2, dy: 0)
    }
}
