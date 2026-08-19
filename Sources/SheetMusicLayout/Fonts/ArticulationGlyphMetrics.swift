#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Runtime-measured vertical anchoring offset for the SMuFL articulation
/// glyphs in Bravura.
///
/// Both renderers (`ScoreLayerBuilder.glyphLayer` and
/// `GraphicsContext.drawGlyph`) anchor a glyph by its `.center` point — the
/// typographic frame center, NOT the visible ink. MuseScore instead centers
/// the symbol's ink bbox on its computed reference Y
/// (`Chord::layoutArticulations`: `y -= a->height() * .5`). The staccato dot,
/// staccatissimo wedge, and tenuto bar all sit slightly off the typographic
/// center, so a glyph anchored naively renders ~0.17 sp too far from the note.
///
/// The layout queries this offset and shifts `origin.y` inward so the rendered
/// ink center lands exactly on the reference Y, matching MuseScore.
public enum ArticulationGlyphMetrics {
    /// Screen-Y-down distance (at `fontSize = 4`, i.e. 1 sp = 1 unit) from the
    /// `.center`-anchored `origin.y` to the glyph's INK center. Callers scale
    /// by their own `metrics.sp` and subtract from the reference Y.
    public static func inkCenterOffset(codepoint: UInt16) -> CGFloat {
        let bravuraEm = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        let provider = FontMetrics.provider
        let ascent = provider.ascent(font: bravuraEm)
        let descent = provider.descent(font: bravuraEm)
        // `.center` puts the typographic center at origin.y; the baseline sits
        // `(ascent - descent) / 2` below it (screen-Y-down).
        let baselineFromCenter = (ascent - descent) / 2
        guard let bbox = provider.glyphPathBoundingBox(
            font: bravuraEm, codepoint: codepoint,
        ) else {
            return 0
        }
        // bbox is CT (Y-up) about the baseline; ink center below origin.y is
        // baselineFromCenter (baseline) minus the Y-up ink center.
        return baselineFromCenter - bbox.midY
    }
}
