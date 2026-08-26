#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Brace SMuFL glyph metrics needed at layout time.
///
/// Mirrors `engraving/dom/bracket.cpp::Bracket::computeMagx` (`magx`
/// formula) and the Bravura brace-variant table that the SheetMusicUI
/// renderer also consults — exposing the same numbers in the layout
/// layer so the part-label gutter can reserve enough horizontal space
/// for tall braces (where the rendered glyph extends much further left
/// than `bracketColumnCount × sp`).
public enum BraceMetrics {
    /// `(codepoint, magx)` for the given staff span, matching MuseScore's
    /// `Bracket::computeMagx`:
    ///   v=1 → braceSmall, v=2 → brace, v=3 → braceLarge, v≥4 → braceLarger.
    /// `magx = v + (v − 1) × 1.625` for v ≥ 2; 1 for v = 1.
    public static func variant(
        staffCount: Int,
    ) -> (codepoint: UInt16, magx: CGFloat) {
        let v = max(staffCount, 1)
        let magx: CGFloat = v == 1
            ? 1
            : CGFloat(v) + CGFloat(v - 1) * 1.625
        let codepoint: UInt32
        switch v {
        case 1: codepoint = SMuFLCodepoint.braceSmall
        case 2: codepoint = SMuFLCodepoint.brace
        case 3: codepoint = SMuFLCodepoint.braceLarge
        default: codepoint = SMuFLCodepoint.braceLarger
        }
        return (UInt16(codepoint), magx)
    }

    /// Horizontal extent of the rendered brace glyph for a span of
    /// `staffCount` staves at the given `sp`. Equals
    /// `bbox.width × magx` where `bbox.width` is the variant glyph's
    /// natural bounding-box width measured at `fontSize = sp × 4`
    /// (Bravura's 1 em = 4 sp).
    public static func glyphHorizontalExtent(
        staffCount: Int, sp: CGFloat,
    ) -> CGFloat {
        let (codepoint, magx) = variant(staffCount: staffCount)
        let naturalAtUnitSp = naturalBBoxWidth(codepoint: codepoint)
        return naturalAtUnitSp * sp * magx
    }

    /// Natural bbox.width measured at `fontSize = 4` (i.e. sp = 1) so
    /// the cached value is in sp-units; callers scale by their own sp.
    /// Provider owns its own per-(face,size) cache, so we just ask
    /// each time — no local cache needed.
    private static func naturalBBoxWidth(codepoint: UInt16) -> CGFloat {
        let bbox = FontMetrics.provider.glyphPathBoundingBox(
            font: LayoutFont(face: SMuFLFamily.bravura, pointSize: 4),
            codepoint: codepoint,
        )
        return bbox?.width ?? 0
    }
}
