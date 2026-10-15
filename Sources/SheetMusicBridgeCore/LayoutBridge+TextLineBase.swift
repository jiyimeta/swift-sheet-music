import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

extension LayoutBridge {
    /// A text-line-family segment (pedal, text line, palm mute, let ring, the guitar lines) in the draw program, with
    /// the opcodes it already had: the labels' runs (`emitRichText`), then each stroke of
    /// `SpannerGeometry.textLineBase` as a polyline, bracketed by `setDash` at that stroke's own pattern and its reset
    /// when the stroke is not solid.
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
        // `DrawCommand` has no cap opcode, and MuseScore's dot is a 0.01-line-width dash made round by its cap
        // (`tdraw.cpp:1524-1538`) — with the butt cap every draw-program backend uses, that is an invisible sliver.
        // So a dotted stroke is drawn as square dots one line width long on the same two-line-width period until the
        // draw program can say "round" (a new opcode is a draw-program version change).
        for stroke in parts.strokes {
            let dashed = stroke.dashPattern.count == 2
            if dashed {
                let thickness = Double(parts.thickness)
                let on = (stroke.roundCap ? thickness : Double(stroke.dashPattern[0])) * ptToMMScale
                let off = (stroke.roundCap ? thickness : Double(stroke.dashPattern[1])) * ptToMMScale
                out.append(.setDash(onMM: on, offMM: off))
            }
            emitPolyline(stroke.points, lineWidth: Double(parts.thickness), into: &out)
            if dashed {
                out.append(.setDash(onMM: 0, offMM: 0))
            }
        }
    }
}
