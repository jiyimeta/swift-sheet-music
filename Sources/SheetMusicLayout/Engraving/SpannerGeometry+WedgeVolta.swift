#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// A wedge hairpin placed beside its texts: the two ends the strokes run between, and where each label hangs (anchor
/// `LayoutRichText.anchor(for: .lineLabel)`, i.e. top-left).
public struct WedgeTextParts: Sendable, Equatable {
    public let from: CGPoint
    public let to: CGPoint
    public let beginOrigin: CGPoint?
    public let endOrigin: CGPoint?
}

extension SpannerGeometry {
    /// How far a wedge's begin and end texts push its two ends inward: `text.width + 0.5 sp` each, `0` without text
    /// (`tlayout.cpp:2904-2913, 2920-2922`).
    public static func wedgeTextShift(
        begin: LayoutRichText?, end: LayoutRichText?, sp: CGFloat,
    ) -> (startShift: CGFloat, endShift: CGFloat) {
        let gap = sp * textLineBaseLabelGapSp
        return (begin.map { $0.size.width + gap } ?? 0, end.map { $0.size.width + gap } ?? 0)
    }

    /// The ends of a wedge's strokes and the origins of its texts. The begin text is left-aligned at `from`, the end
    /// text right-aligned at `to`, both vertically centered on the wedge's axis (`setBeginTextAlign` LEFT/VCENTER,
    /// `setEndTextAlign` RIGHT/VCENTER, `tlayout.cpp:2904-2907`); the strokes keep a spatium of length at least
    /// (`:2923-2925`).
    public static func wedgeText(
        from: CGPoint, to: CGPoint, begin: LayoutRichText?, end: LayoutRichText?, sp: CGFloat,
    ) -> WedgeTextParts {
        let shift = wedgeTextShift(begin: begin, end: end, sp: sp)
        let axisY = max(from.y, to.y)
        let strokeTo = max(to.x - shift.endShift, from.x + sp)
        let strokeFrom = min(from.x + shift.startShift, strokeTo)
        return WedgeTextParts(
            from: CGPoint(x: strokeFrom, y: from.y),
            to: CGPoint(x: strokeTo, y: to.y),
            beginOrigin: begin.map { CGPoint(x: from.x, y: axisY - $0.size.height / 2) },
            endOrigin: end.map { CGPoint(x: to.x - $0.size.width, y: axisY - $0.size.height / 2) },
        )
    }

    /// Where a volta's label hangs (anchor `(0, 0.5)`: leading edge, vertically centered): a spatium in from the
    /// bracket's left end and half a spatium below its top, the top being the higher of the two ends.
    public static func voltaLabelOrigin(from: CGPoint, to: CGPoint, sp: CGFloat) -> CGPoint {
        CGPoint(x: from.x + sp, y: min(from.y, to.y) + sp / 2)
    }

    /// The label folino-made voltas fall back to when no `<beginText>` is authored — "1." or "1, 2." — or `nil` for a
    /// volta with no endings. MuseScore has no such label (`dom/volta.cpp:139-151`).
    public static func voltaLabelText(endings: [Int]) -> String? {
        guard !endings.isEmpty else { return nil }
        return endings.map(String.init).joined(separator: ", ") + "."
    }
}
