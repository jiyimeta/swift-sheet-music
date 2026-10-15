import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

extension LayoutBridge {
    /// A gradual tempo line in the draw program, with the opcodes it already had: the label's runs and the end
    /// label's (`emitRichText`), then `setDash` at MuseScore's pattern, the line, and the dash reset.
    static func encodeGradualTempoChange(
        from: TextInkPoint, to: TextInkPoint, richText: LayoutRichText?, endRichText: LayoutRichText?, sp: Double,
        into out: inout [DrawCommand],
    ) {
        let parts = SpannerGeometry.gradualTempoChange(
            from: from, to: to, label: richText, endLabel: endRichText, sp: CGFloat(sp),
        )
        let anchor = LayoutRichText.anchor(for: .gradualTempoChangeLabel)
        if let richText {
            emitRichText(richText, origin: parts.labelOrigin, anchor: anchor, into: &out)
        }
        if let endRichText, let origin = parts.endLabelOrigin {
            emitRichText(endRichText, origin: origin, anchor: anchor, into: &out)
        }
        guard parts.lineEnd.x > parts.lineStart.x else { return }
        out.append(.setDash(
            onMM: Double(parts.dashPattern[0]) * ptToMMScale, offMM: Double(parts.dashPattern[1]) * ptToMMScale,
        ))
        emitSegment(from: parts.lineStart, to: parts.lineEnd, lineWidth: Double(parts.lineThickness), into: &out)
        out.append(.setDash(onMM: 0, offMM: 0))
    }
}
