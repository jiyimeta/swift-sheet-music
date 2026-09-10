import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

extension LayoutBridge {
    /// Converts the same whole-stack/ink anchor the Apple renderer uses into baseline commands.
    /// Newlines never reach a native single-line drawText call; blank lines still move the baseline.
    static func emitAnchoredText(
        text: String, font: LayoutFont, origin: CGPoint, anchor: CGPoint,
        fontID: DrawProgram.FontID = .textRoman, into out: inout [DrawCommand],
    ) {
        let provider = FontMetrics.provider
        guard provider.textInkBounds(text: text, font: font) != nil else { return }
        let baseline = TextInkGeometry.baselineOrigin(text: text, font: font, origin: origin, anchor: anchor)
        emitBaselineText(text: text, font: font, baseline: baseline, fontID: fontID, into: &out)
    }

    static func emitBaselineText(
        text: String, font: LayoutFont, baseline: CGPoint,
        fontID: DrawProgram.FontID, into out: inout [DrawCommand],
    ) {
        let provider = FontMetrics.provider
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

    static func emitRoleText(
        text: String, style: TextStyleType, originX: Double, originY: Double,
        sp: Double, anchor: CGPoint, into out: inout [DrawCommand],
    ) {
        let font = TextInkGeometry.font(for: style, metrics: StaffMetrics(staffSize: CGFloat(sp) * 4))
        withTextStyle(styleFlags(for: style), into: &out) { out in
            emitAnchoredText(
                text: text,
                font: font,
                origin: CGPoint(x: originX, y: originY),
                anchor: anchor,
                into: &out,
            )
        }
    }
}
