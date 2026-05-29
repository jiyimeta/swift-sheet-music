#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// Per-glyph offsets describing where the visible breath/caesura glyph
/// sits relative to `origin.y` when drawn with anchor `.center`
/// (the convention used by `GraphicsContext.drawGlyph` and
/// `ScoreLayerBuilder.glyphLayer`). Positive Y = lower on screen
/// (CG screen-Y-down). Mirrors `FermataGlyphOffsets`.
///
/// All values are at `fontSize = 4` (i.e. 1 sp = 1 unit), so callers
/// scale by their own `metrics.sp`.
public struct BreathGlyphOffsets: Sendable {
    public let bottomOffset: CGFloat
    public let topOffset: CGFloat
}

/// Runtime-measured offsets for the SMuFL breath/caesura glyphs in
/// Bravura.
///
/// The layout engine uses these to position a breath `origin.y` such
/// that the visible glyph EDGE — not its typographic bbox — sits a
/// known distance above the top staff line. Mirrors
/// `FermataGlyphMetrics` so the same anchor-correction reasoning
/// applies (Bravura's ascent/descent are asymmetric).
public enum BreathGlyphMetrics {
    public static func offsets(forKind kind: Breath.Kind) -> BreathGlyphOffsets {
        offsets(for: BreathGlyph.codepoint(forKind: kind))
    }

    private static func offsets(for codepoint: UInt32) -> BreathGlyphOffsets {
        let bravuraEm = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        let provider = FontMetrics.provider
        let ascent = provider.ascent(font: bravuraEm)
        let descent = provider.descent(font: bravuraEm)
        // Anchor .center puts the text view's typographic CENTRE at
        // origin.y. Text view height = ascent + descent. The baseline
        // therefore sits `(ascent - descent) / 2` BELOW origin in
        // screen-Y-down coords.
        let baselineFromCenter = (ascent - descent) / 2
        guard let bbox = provider.glyphPathBoundingBox(
            font: bravuraEm, codepoint: UInt16(codepoint),
        ) else {
            // Defensive fallback (provider has no glyph for codepoint).
            return BreathGlyphOffsets(
                bottomOffset: baselineFromCenter,
                topOffset: baselineFromCenter - 0.7,
            )
        }
        return BreathGlyphOffsets(
            bottomOffset: baselineFromCenter - bbox.minY,
            topOffset: baselineFromCenter - bbox.maxY,
        )
    }
}
