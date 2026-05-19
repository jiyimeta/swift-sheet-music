#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Offset that converts a glyph emitted with `.center` anchor (visual
/// ink centre at `(x, y)`) into a baseline-leading anchor (typographic
/// origin at `(x, y)`).
///
/// `LayoutEngine` emits glyph origins in the Apple SwiftUI convention:
/// the visual ink centre coincides with the placed `(x, y)`. The
/// Android `Canvas.drawText` API anchors at the baseline-leading
/// position instead, so the bridge applies this conversion before
/// writing the wire-format glyph command.
///
/// Both Apple's `CTFontCreatePathForGlyph().boundingBox` and the
/// precomputed `SMuFLMetricsTable` return the glyph bounding box in
/// y-up font coordinates — `bbox.midY > 0` means the visual centre
/// sits above the baseline. The conversion is therefore:
///
///     leading.x   = center.x - bbox.midX
///     baseline.y  = center.y + bbox.midY   // y-down screen coords
public enum GlyphAnchor {
    /// `(dx, dy)` to add to a center-anchor `(x, y)` to obtain the
    /// baseline-leading position, given the glyph's y-up font bbox.
    /// Returns `(0, 0)` when the bbox is unavailable.
    public static func centerToBaselineLeading(
        bbox: CGRect?,
    ) -> (dx: CGFloat, dy: CGFloat) {
        guard let bbox else { return (0, 0) }
        return (dx: -bbox.midX, dy: bbox.midY)
    }
}
