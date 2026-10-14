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
    /// The band a gradual line reserves: its label's height in the tempo change font (12 pt at the reference spatium).
    public static let gradualTempoChangeHeightSp: CGFloat = 2.4

    public struct GradualTempoChangeParts: Sendable, Equatable {
        /// Where the label's runs hang, by `LayoutRichText.anchor(for: .gradualTempoChangeLabel)`.
        public let labelOrigin: CGPoint
        public let lineStart: CGPoint
        public let lineEnd: CGPoint
        public let lineThickness: CGFloat
        /// Dash and gap, in points.
        public let dashPattern: [CGFloat]
    }

    /// A gradual tempo line from `from` to `to`: its label hung at `from`, the dashed line from half a space after the
    /// label — from `from` itself when there is none — to `to`. MuseScore's end hook and end text are not drawn.
    public static func gradualTempoChange(
        from: CGPoint, to: CGPoint, label: LayoutRichText?, sp: CGFloat,
    ) -> GradualTempoChangeParts {
        let labelWidth = label?.size.width ?? 0
        let start = labelWidth > 0 ? from.x + labelWidth + sp * gradualTempoChangeLabelGapSp : from.x
        return GradualTempoChangeParts(
            labelOrigin: from,
            lineStart: CGPoint(x: min(start, to.x), y: from.y),
            lineEnd: to,
            lineThickness: sp * gradualTempoChangeLineThicknessSp,
            dashPattern: [sp * gradualTempoChangeDashSp, sp * gradualTempoChangeGapSp],
        )
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
