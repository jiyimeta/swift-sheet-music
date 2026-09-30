import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

extension LayoutBridge {
    #if canImport(CoreGraphics)
        typealias TextInkPoint = CGPoint
    #else
        typealias TextInkPoint = SheetMusicLayout.CGPoint
    #endif

    /// Converts the same whole-stack/ink anchor the Apple renderer uses into baseline commands.
    /// Newlines never reach a native single-line drawText call; blank lines still move the baseline.
    ///
    /// `font` is what the anchor is measured in, so it also decides the face id and the `setTextStyle` bits
    /// (`TextFontMapping`), wrapped around the whole emit and restored after it: a reader that draws the id draws
    /// the face whose ink the anchor was resolved against. Callers never pick either.
    static func emitAnchoredText(
        text: String, font: LayoutFont, origin: TextInkPoint, anchor: TextInkPoint,
        into out: inout [DrawCommand],
    ) {
        withTextStyle(TextFontMapping.wire(for: font).style, into: &out) { out in
            let provider = FontMetrics.provider
            guard provider.textInkBounds(text: text, font: font) != nil else { return }
            let baseline = TextInkGeometry.baselineOrigin(text: text, font: font, origin: origin, anchor: anchor)
            emitBaselineText(text: text, font: font, baseline: baseline, into: &out)
        }
    }

    /// One `.text` per line of `text` at `baseline`, in `font`'s face id (`TextFontMapping`). The caller wraps it in
    /// `font`'s style bits, as `emitAnchoredText` does.
    static func emitBaselineText(
        text: String, font: LayoutFont, baseline: TextInkPoint, into out: inout [DrawCommand],
    ) {
        let provider = FontMetrics.provider
        let fontID = TextFontMapping.wire(for: font).fontId
        let stride = provider.ascent(font: font) + provider.descent(font: font) + provider.leading(font: font)
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.isEmpty
        {
            out.append(.text(
                text: String(line), x: Double(baseline.x) * ptToMMScale,
                y: Double(baseline.y + CGFloat(index) * stride) * ptToMMScale,
                size: Double(font.pointSize) * ptToMMScale, fontId: fontID,
            ))
        }
    }

    /// `properties` is the element's font override. Its size reaches the wire through the `.text` command's own
    /// size and its bold/italic through `setTextStyle`, both from the font it resolves to; its face reaches the wire
    /// only as far as `TextFontMapping` can say it (a named face is `.textRoman`), as a chord symbol's does
    /// (`encodeHarmony`).
    static func emitRoleText(
        text: String, style: TextStyleType, properties: TextProperties = TextProperties(),
        originX: Double, originY: Double, sp: Double, anchor: TextInkPoint, into out: inout [DrawCommand],
    ) {
        emitAnchoredText(
            text: text,
            font: TextInkGeometry.font(
                for: style, overrides: properties, metrics: StaffMetrics(staffSize: CGFloat(sp) * 4),
            ),
            origin: TextInkPoint(x: originX, y: originY),
            anchor: anchor,
            into: &out,
        )
    }
}
