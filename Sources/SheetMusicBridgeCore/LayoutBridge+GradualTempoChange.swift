import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

extension LayoutBridge {
    /// A gradual tempo line in the draw program, with the opcodes it already had: the label's runs
    /// (`emitRichText`), then `setDash` at MuseScore's pattern, the line, and the dash reset.
    static func encodeGradualTempoChange(
        from: CGPoint, to: CGPoint, richText: LayoutRichText?, sp: Double, into out: inout [DrawCommand],
    ) {
        let parts = SpannerGeometry.gradualTempoChange(from: from, to: to, label: richText, sp: CGFloat(sp))
        if let richText {
            emitRichText(
                richText, origin: parts.labelOrigin,
                anchor: LayoutRichText.anchor(for: .gradualTempoChangeLabel), into: &out,
            )
        }
        guard parts.lineEnd.x > parts.lineStart.x else { return }
        out.append(.setDash(
            onMM: Double(parts.dashPattern[0]) * ptToMMScale, offMM: Double(parts.dashPattern[1]) * ptToMMScale,
        ))
        emitSegment(from: parts.lineStart, to: parts.lineEnd, lineWidth: Double(parts.lineThickness), into: &out)
        out.append(.setDash(onMM: 0, offMM: 0))
    }
}
