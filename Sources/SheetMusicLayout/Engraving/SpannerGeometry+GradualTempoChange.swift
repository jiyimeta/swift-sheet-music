#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension SpannerGeometry {
    /// MuseScore's gradual tempo change line (`Sid::tempoChange*`, `engraving/style/styledef.cpp:1168-1190`): 0.15 sp
    /// thick (`tempoChangeLineWidth`), dashed at 6 and 9 line widths (`tempoChangeDashLineLen` / `…DashGapLen`).
    public static let gradualTempoChangeLineThicknessSp: CGFloat = 0.15
    public static let gradualTempoChangeDashSp: CGFloat = 0.9
    public static let gradualTempoChangeGapSp: CGFloat = 1.35
    /// The clearance between the label and the line (`TextLineBaseSegment` layout, `textlinebase.cpp:556-557`).
    public static let gradualTempoChangeLabelGapSp: CGFloat = 0.5

    public struct GradualTempoChangeParts: Sendable, Equatable {
        /// Where the label's runs hang, by `LayoutRichText.anchor(for: .gradualTempoChangeLabel)` (its top-left): the
        /// label's first baseline lands on the segment's `from.y`.
        public let labelOrigin: CGPoint
        public let lineStart: CGPoint
        public let lineEnd: CGPoint
        public let lineThickness: CGFloat
        /// Dash and gap, in points.
        public let dashPattern: [CGFloat]
    }

    /// A gradual tempo line from `from` to `to`. `from.y` is the label's baseline (`tempoChangeAlign` = LEFT, BASELINE,
    /// `styledef.cpp:1174`); the dashed line starts half a space after the label — at `from` itself when there is
    /// none — and, with a label, runs lifted by half its width so the label's baseline sits on the line's lower edge
    /// (`alignBaseLine`, `tlayout.cpp:5750-5768`). MuseScore's end hook and end text are not drawn.
    public static func gradualTempoChange(
        from: CGPoint, to: CGPoint, label: LayoutRichText?, sp: CGFloat,
    ) -> GradualTempoChangeParts {
        let labelWidth = label?.size.width ?? 0
        let start = labelWidth > 0 ? from.x + labelWidth + sp * gradualTempoChangeLabelGapSp : from.x
        let thickness = sp * gradualTempoChangeLineThicknessSp
        let lineY = label == nil ? from.y : from.y - thickness / 2
        return GradualTempoChangeParts(
            labelOrigin: CGPoint(x: from.x, y: from.y - (label?.firstBaseline ?? 0)),
            lineStart: CGPoint(x: min(start, to.x), y: lineY),
            lineEnd: CGPoint(x: to.x, y: lineY),
            lineThickness: thickness,
            dashPattern: [sp * gradualTempoChangeDashSp, sp * gradualTempoChangeGapSp],
        )
    }

    /// The ink a gradual tempo line occupies, for the skyline and the system's height: the label's ink and the line's
    /// stroke, placed by `gradualTempoChange(from:to:label:sp:)`.
    static func gradualTempoChangeInk(
        from: CGPoint, to: CGPoint, label: LayoutRichText?, sp: CGFloat,
    ) -> CGRect {
        let parts = gradualTempoChange(from: from, to: to, label: label, sp: sp)
        let line = CGRect(
            x: parts.lineStart.x, y: parts.lineStart.y - parts.lineThickness / 2,
            width: max(0, parts.lineEnd.x - parts.lineStart.x), height: parts.lineThickness,
        )
        let anchor = LayoutRichText.anchor(for: .gradualTempoChangeLabel)
        guard let ink = label?.inkRect(at: parts.labelOrigin, anchor: anchor) else { return line }
        return line.union(ink)
    }
}

extension LayoutRichText {
    /// A gradual tempo change's label — `<beginText>` or `<continueText>`, MuseScore xml text — typeset in the tempo
    /// change style (`Sid::tempoChangeFont*`, Edwin 12 bold and spatium-dependent: the tempo row) with its symbols at
    /// `tempoChangeMusicalSymbolSize` (12, `styledef.cpp:2073`). `nil` for an empty label: MuseScore draws no default
    /// text (`GradualTempoChange` resets `BEGIN_TEXT` to "", `gradualtempochange.cpp:229-233`).
    package static func gradualTempoChangeLabel(_ xmlText: String?, metrics: StaffMetrics) -> LayoutRichText? {
        guard let xmlText, !xmlText.isEmpty else { return nil }
        let pointScale = metrics.sp / TextRoleStyle.referenceSpatiumInPoints
        return LayoutRichText(
            RichText(xmlText: xmlText),
            baseFont: TextInkGeometry.font(for: .tempo, metrics: metrics),
            pointScale: pointScale,
            symbolPointSize: 12 * pointScale,
        )
    }
}
