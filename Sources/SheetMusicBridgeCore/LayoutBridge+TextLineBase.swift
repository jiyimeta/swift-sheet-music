import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

extension LayoutBridge {
    /// A text-line-family segment (pedal, text line, palm mute, let ring, the guitar lines) in the draw program, with
    /// the opcodes it already had: the labels' runs (`emitRichText`), then each stroke of
    /// `SpannerGeometry.textLineBase` as a polyline, bracketed by `setDash` and its reset when the line is not solid.
    static func encodeTextLineBase(
        from: TextInkPoint, to: TextInkPoint, richText: LayoutRichText?, lineDetail: LayoutLineDetail, sp: Double,
        into out: inout [DrawCommand],
    ) {
        let parts = SpannerGeometry.textLineBase(
            from: from, to: to, label: richText, detail: lineDetail, sp: CGFloat(sp),
        )
        let anchor = LayoutRichText.anchor(for: .lineLabel)
        if let richText, let origin = parts.beginOrigin {
            emitRichText(richText, origin: origin, anchor: anchor, into: &out)
        }
        if let endLabel = lineDetail.endRichText, let origin = parts.endOrigin {
            emitRichText(endLabel, origin: origin, anchor: anchor, into: &out)
        }
        guard !parts.strokes.isEmpty else { return }
        if parts.dashPattern.count == 2 {
            out.append(.setDash(
                onMM: Double(parts.dashPattern[0]) * ptToMMScale, offMM: Double(parts.dashPattern[1]) * ptToMMScale,
            ))
        }
        for stroke in parts.strokes {
            emitPolyline(stroke, lineWidth: Double(parts.thickness), into: &out)
        }
        if parts.dashPattern.count == 2 {
            out.append(.setDash(onMM: 0, offMM: 0))
        }
    }
}
