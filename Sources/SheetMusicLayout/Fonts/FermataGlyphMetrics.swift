#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Per-glyph offsets describing where the visible glyph sits relative
/// to `origin.y` when `Text(glyph)` is drawn with anchor `.center`
/// (the convention used by `GraphicsContext.drawGlyph` and
/// `ScoreLayerBuilder.glyphLayer`). Positive Y = lower on screen
/// (CG screen-Y-down).
///
/// All values are at `fontSize = 4` (i.e. 1 sp = 1 unit), so callers
/// scale by their own `metrics.sp`.
public struct FermataGlyphOffsets: Sendable {
    public let bottomOffset: CGFloat
    public let topOffset: CGFloat
}

/// Runtime-measured offsets for the SMuFL fermata glyphs in Bravura.
///
/// The layout engine uses these to position the fermata `origin.y`
/// such that the visible glyph EDGE — not its typographic bbox —
/// clears the chord skyline by a known gap.
public enum FermataGlyphMetrics {
    /// fermataAbove (U+E4C0).
    public static var above: FermataGlyphOffsets {
        offsets(for: 0xE4C0)
    }

    /// fermataBelow (U+E4C1).
    public static var below: FermataGlyphOffsets {
        offsets(for: 0xE4C1)
    }

    private static func offsets(for codepoint: UInt16) -> FermataGlyphOffsets {
        let bravuraEm = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        let provider = FontMetrics.provider
        let ascent = provider.ascent(font: bravuraEm)
        let descent = provider.descent(font: bravuraEm)
        // Anchor .center puts the text view's typographic CENTER at
        // origin.y. Text view height = ascent + descent. The baseline
        // therefore sits `(ascent - descent) / 2` BELOW origin in
        // screen-Y-down coords.
        let baselineFromCenter = (ascent - descent) / 2
        guard let bbox = provider.glyphPathBoundingBox(
            font: bravuraEm, codepoint: codepoint,
        ) else {
            // Defensive fallback (provider has no glyph for codepoint).
            return FermataGlyphOffsets(
                bottomOffset: baselineFromCenter,
                topOffset: baselineFromCenter - 0.7,
            )
        }
        return FermataGlyphOffsets(
            bottomOffset: baselineFromCenter - bbox.minY,
            topOffset: baselineFromCenter - bbox.maxY,
        )
    }
}
