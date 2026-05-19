#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Offset that converts a glyph emitted with SwiftUI's `.center`
/// anchor into a baseline-leading anchor (the position
/// `Canvas.drawText` on Android takes).
///
/// `LayoutEngine` emits glyph origins assuming Apple's
/// `context.draw(resolved, at:, anchor: .center)` semantics. SwiftUI
/// resolves a single-character `Text` to its **typographic frame**
/// (advance × line-height), not the ink-path bbox; `.center` centres
/// that frame on `(x, y)`. The conversion is therefore based on
/// `advance` (horizontal) and the asymmetry of `ascent`/`descent`
/// (vertical), NOT on the path bbox:
///
///     leading.x  = center.x - advance / 2
///     baseline.y = center.y + (ascent - descent) / 2   // y-down screen
///
/// The bbox-based variant used in an earlier version of this helper
/// was off by ~1 sp for tall glyphs like the treble clef because the
/// ink extends much higher above the baseline than the typographic
/// frame admits.
public enum GlyphAnchor {
    /// `(dx, dy)` to add to a `.center`-anchor `(x, y)` to obtain the
    /// baseline-leading position. Uses the glyph's typographic metrics
    /// (advance, ascent, descent) — these come from the same
    /// FontMetricsProvider that the bridge already consults.
    public static func centerToBaselineLeading(
        advance: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
    ) -> (dx: CGFloat, dy: CGFloat) {
        (dx: -advance / 2, dy: (ascent - descent) / 2)
    }
}
