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
    static func wedgeTextShift(
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

    /// The left end of a volta label's first baseline: `voltaOffset` (0.6, 2.2) sp from the bracket's left end, the
    /// line being the higher of the two ends. MuseScore aligns the label LEFT, BASELINE there and places it BELOW the
    /// line (`voltaAlign`, `styledef.cpp:625-626`; `Volta::Volta` sets `TextPlace::BELOW`, `volta.cpp:111-112`), so it
    /// hangs inside the hook, its baseline level with the hook's end, and the line runs on over it.
    static func voltaLabelBaseline(from: CGPoint, to: CGPoint, sp: CGFloat) -> CGPoint {
        CGPoint(x: from.x + sp * 0.6, y: min(from.y, to.y) + sp * voltaHookSp)
    }

    /// Where a volta's typeset label hangs by its top-left (`LayoutRichText.anchor(for: .lineLabel)`): the origin that
    /// puts its first baseline on `voltaLabelBaseline`.
    public static func voltaLabelOrigin(from: CGPoint, to: CGPoint, label: LayoutRichText, sp: CGFloat) -> CGPoint {
        let baseline = voltaLabelBaseline(from: from, to: to, sp: sp)
        return CGPoint(x: baseline.x, y: baseline.y - label.firstBaseline)
    }

    /// Where the plain endings label of a hand-built segment (one that carries no typeset label) hangs by its leading
    /// edge, vertically centered (anchor `(0, 0.5)`): the middle of its capitals, about 0.35 of its `voltaLabelSizeSp`
    /// size above the same baseline.
    public static func voltaLabelOrigin(from: CGPoint, to: CGPoint, sp: CGFloat) -> CGPoint {
        let baseline = voltaLabelBaseline(from: from, to: to, sp: sp)
        return CGPoint(x: baseline.x, y: baseline.y - sp * voltaLabelSizeSp * 0.35)
    }

    /// A volta segment's ink: the line with its stroke's half on either side, the hooks it draws (ending square at
    /// their depth) and its label below. A segment that continues at both ends draws no hook.
    public static func voltaInk(
        from: CGPoint, to: CGPoint, continuesLeft: Bool, continuesRight: Bool, label: LayoutRichText?, sp: CGFloat,
    ) -> CGRect {
        let top = min(from.y, to.y)
        let halfStroke = sp * strokeThicknessSp / 2
        let hookDepth = continuesLeft && continuesRight ? 0 : sp * voltaHookSp
        var ink = CGRect(
            x: min(from.x, to.x), y: top - halfStroke,
            width: abs(to.x - from.x), height: halfStroke + max(halfStroke, hookDepth),
        )
        if let label, !label.lines.allSatisfy(\.runs.isEmpty) {
            let origin = voltaLabelOrigin(from: from, to: to, label: label, sp: sp)
            ink = ink.union(CGRect(origin: origin, size: label.size))
        }
        return ink
    }

    /// The label folino-made voltas fall back to when no `<beginText>` is authored — "1." or "1, 2." — or `nil` for a
    /// volta with no endings. MuseScore has no such label (`dom/volta.cpp:139-151`).
    public static func voltaLabelText(endings: [Int]) -> String? {
        guard !endings.isEmpty else { return nil }
        return endings.map(String.init).joined(separator: ", ") + "."
    }
}
