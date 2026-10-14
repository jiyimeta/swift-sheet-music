#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutRichText {
    /// A dynamic's `<sym>` size, in points: the music font at its SMuFL size — `DEFAULT_SMUFL_POINT_SIZE`, four
    /// reference spaces — times the dynamic's symbol scale (1) and the spatium scaling (`TextFragment::font`,
    /// `engraving/dom/textbase.cpp:881-898`; `style/styledef.h:2233-2239`): 4 sp, the size a plain dynamic's glyphs are
    /// drawn at (`TextMarkRenderer.drawDynamic`).
    static func dynamicSymbolPointSize(metrics: StaffMetrics) -> CGFloat {
        metrics.sp * 4
    }

    /// A dynamic's own text typeset: words in the dynamics style (Edwin 10 italic, spatium-dependent) with the
    /// dynamic's font override, `<sym>` runs in Bravura at `dynamicSymbolPointSize`.
    static func dynamic(_ richText: RichText, properties: TextProperties, metrics: StaffMetrics) -> LayoutRichText {
        let resolved = properties.resolved(against: .dynamics)
        let pointScale = resolved.spatiumDependent ? metrics.sp / TextRoleStyle.referenceSpatiumInPoints : 1
        return LayoutRichText(
            richText,
            baseFont: TextInkGeometry.font(for: .dynamics, overrides: properties, metrics: metrics),
            pointScale: pointScale,
            symbolPointSize: dynamicSymbolPointSize(metrics: metrics),
            underline: resolved.style.contains(.underline),
            strike: resolved.style.contains(.strike),
        )
    }

    /// The origin that sets this block, hung by `anchor`, with its first line's baseline at `baseline.y`; x unchanged.
    func origin(firstBaselineAt baseline: CGPoint, anchor: CGPoint) -> CGPoint {
        CGPoint(x: baseline.x, y: baseline.y - (lineBaselines.first ?? 0) + anchor.y * size.height)
    }
}
