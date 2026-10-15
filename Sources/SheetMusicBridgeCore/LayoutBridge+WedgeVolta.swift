import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

extension LayoutBridge {
    /// A wedge hairpin in the draw program: its begin and end texts' runs, then the two strokes between the ends
    /// `SpannerGeometry.wedgeText` leaves them, with the opcodes the wedge already had.
    static func encodeWedge(
        from: TextInkPoint, to: TextInkPoint, open: Bool, richText: LayoutRichText?, endRichText: LayoutRichText?,
        sp: Double, lineWidth: Double, into out: inout [DrawCommand],
    ) {
        let wedge = SpannerGeometry.wedgeText(from: from, to: to, begin: richText, end: endRichText, sp: CGFloat(sp))
        let anchor = LayoutRichText.anchor(for: .lineLabel)
        if let richText, let origin = wedge.beginOrigin {
            emitRichText(richText, origin: origin, anchor: anchor, into: &out)
        }
        if let endRichText, let origin = wedge.endOrigin {
            emitRichText(endRichText, origin: origin, anchor: anchor, into: &out)
        }
        let segs = SpannerGeometry.hairpin(from: wedge.from, to: wedge.to, open: open, sp: CGFloat(sp))
        emitSegment(from: segs.upperFrom, to: segs.upperTo, lineWidth: lineWidth, into: &out)
        emitSegment(from: segs.lowerFrom, to: segs.lowerTo, lineWidth: lineWidth, into: &out)
    }

    /// A volta's label: the segment's typeset text (authored, or the endings label layout synthesized), at the
    /// `(0, 0.5)` anchor. Only a segment that carries none (hand-built) falls back to the plain endings label, and
    /// never in addition to a typeset one.
    static func encodeVoltaLabel(
        from: TextInkPoint, to: TextInkPoint, endings: [Int], continuesLeft: Bool, richText: LayoutRichText?,
        sp: Double, into out: inout [DrawCommand],
    ) {
        let origin = SpannerGeometry.voltaLabelOrigin(from: from, to: to, sp: CGFloat(sp))
        if let richText {
            emitRichText(richText, origin: origin, anchor: TextInkPoint(x: 0, y: 0.5), into: &out)
        } else if !continuesLeft, let text = SpannerGeometry.voltaLabelText(endings: endings) {
            encodeNotationText(
                text: text, role: .markerText, originX: Double(origin.x), originY: Double(origin.y), sp: sp,
                into: &out,
            )
        }
    }
}
