#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Pedal symbols use leading ink X and the center of the font's ascent/descent band.
/// Shared by hits and the south skyline so following text clears both painted glyphs.
public enum PedalInkGeometry {
    public static func rects(from: CGPoint, to: CGPoint, metrics: StaffMetrics) -> [CGRect] {
        let glyphs = SpannerGeometry.pedal(from: from, to: to)
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: metrics.glyphFontSize)
        let provider = FontMetrics.provider
        let baseline = (provider.ascent(font: font) - provider.descent(font: font)) / 2
        return [(glyphs.downCodepoint, glyphs.downOrigin), (glyphs.upCodepoint, glyphs.upOrigin)]
            .compactMap { codepoint, origin in
                guard let box = provider.glyphPathBoundingBox(
                    font: font,
                    codepoint: UInt16(truncatingIfNeeded: codepoint),
                ),
                    box.width > 0, box.height > 0 else { return nil }
                return CGRect(x: origin.x, y: origin.y + baseline - box.maxY, width: box.width, height: box.height)
            }
    }
}
