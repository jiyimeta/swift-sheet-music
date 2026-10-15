#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// The typeset label of a line spanner's segment, or `nil` when it draws none: the begin label
    /// (`Spanner.lineLabels`, so layout never re-implements the defaults), or on a later system the continuation. A
    /// gradual tempo change keeps its own tempo-change typesetting (`LayoutRichText.gradualTempoChangeLabel`).
    static func lineLabelRuns(
        kind: LayoutElement.SpannerKind, anchor: SpannerAnchor, clip: SystemClip, metrics: StaffMetrics,
    ) -> LayoutRichText? {
        labelRuns(kind: kind, anchor: anchor, continuesLeft: clip.continuesLeft, metrics: metrics)
    }

    /// The label a segment laid out by `attachSpanners` (the post-pass: voltas and the kinds with no skyline shape)
    /// carries. Only a volta draws typeset text there: its authored `<beginText>` (MuseScore's volta label IS its begin
    /// text, `dom/volta.cpp:139-151`) or, with none, the synthesized endings label folino-made voltas rely on. An
    /// authored empty text yields an empty block, so a renderer draws nothing rather than the synthesized label.
    static func attachedLabelRuns(
        kind: LayoutElement.SpannerKind, anchor: SpannerAnchor, continuesLeft: Bool, metrics: StaffMetrics,
    ) -> LayoutRichText? {
        guard case let .volta(endings) = kind else { return nil }
        let labels = anchor.lineLabels
        if continuesLeft { return typesetLineLabel(labels?.continuation, kind: kind, metrics: metrics) }
        guard let begin = labels?.begin else {
            return typesetLineLabel(SpannerGeometry.voltaLabelText(endings: endings), kind: kind, metrics: metrics)
        }
        if begin.isEmpty { return emptyBlock(kind, metrics) }
        return typesetLineLabel(begin, kind: kind, metrics: metrics)
    }

    private static func emptyBlock(_ kind: LayoutElement.SpannerKind, _ metrics: StaffMetrics) -> LayoutRichText {
        let face = labelFace(for: kind)
        return LayoutRichText(
            RichText(xmlText: ""), style: .staffText, overrides: face.overrides, metrics: metrics,
            symbolSize: face.symbolSize,
        )
    }

    private static func labelRuns(
        kind: LayoutElement.SpannerKind, anchor: SpannerAnchor, continuesLeft: Bool, metrics: StaffMetrics,
    ) -> LayoutRichText? {
        if kind == .gradualTempoChange {
            return LayoutRichText.gradualTempoChangeLabel(
                continuesLeft ? anchor.continueText : anchor.beginText, metrics: metrics,
            )
        }
        guard drawsLabelRuns(kind: kind), let labels = anchor.lineLabels else { return nil }
        return typesetLineLabel(continuesLeft ? labels.continuation : labels.begin, kind: kind, metrics: metrics)
    }

    /// The kinds whose label is typeset text (an ottava, a slur, a vibrato and a trill draw their own).
    private static func drawsLabelRuns(kind: LayoutElement.SpannerKind) -> Bool {
        switch kind {
        case .pedal, .textLine, .palmMute, .letRing, .chordTextLine, .hairpinLine, .hairpinOpen, .hairpinClose,
             .volta: true
        case .slur, .ottava, .vibrato, .trill, .gradualTempoChange: false
        }
    }

    /// A line label's face: the staff-text row (Edwin 10, symbols 10) except where MuseScore's style says otherwise —
    /// a hairpin line and a wedge are italic (`hairpinFontStyle`, `styledef.cpp:293`), a volta is Edwin 11 bold with
    /// symbols 11 (`voltaFontSize` / `voltaFontStyle`, `styledef.cpp:619-623`).
    private static func labelFace(
        for kind: LayoutElement.SpannerKind,
    ) -> (overrides: TextProperties, symbolSize: CGFloat) {
        switch kind {
        case .hairpinLine, .hairpinOpen, .hairpinClose: (TextProperties(style: .italic), 10)
        case .volta: (TextProperties(size: 11, style: .bold), 11)
        default: (TextProperties(), 10)
        }
    }

    /// MuseScore xml text as runs in the kind's face; `nil` for none or empty text.
    private static func typesetLineLabel(
        _ xmlText: String?, kind: LayoutElement.SpannerKind, metrics: StaffMetrics,
    ) -> LayoutRichText? {
        guard let xmlText, !xmlText.isEmpty else { return nil }
        let face = labelFace(for: kind)
        let rich = LayoutRichText(
            RichText(xmlText: xmlText), style: .staffText, overrides: face.overrides, metrics: metrics,
            symbolSize: face.symbolSize,
        )
        return rich.lines.contains { !$0.runs.isEmpty } ? rich : nil
    }

    /// What a line segment draws beside its begin label, resolved with the kind's defaults; `nil` for a kind that is
    /// not a text-line family member. The end label rides only on the segment that ends the line.
    static func lineDetail(
        kind: LayoutElement.SpannerKind, anchor: SpannerAnchor, clip: SystemClip, metrics: StaffMetrics,
    ) -> LayoutLineDetail? {
        let end = clip.continuesRight ? nil : anchor.lineLabels?.end
        var detail = lineDetailDefaults(
            kind: kind, lineProperties: anchor.lineProperties, endText: end,
            placedBelow: isBelowStaff(anchor: anchor), metrics: metrics,
        )
        // A hook belongs to the segment that holds its end of the line (`isSingleOrBegin` / `isSingleOrEnd`).
        if clip.continuesLeft { detail?.beginHook = Spanner.LineHookType.none }
        if clip.continuesRight { detail?.endHook = Spanner.LineHookType.none }
        return detail
    }

    /// `lineDetail` without a `Score`: the hooks, visibility, line type, width and dash of `lineProperties` over the
    /// kind's defaults (`nil` properties are all defaults).
    static func lineDetailDefaults(
        kind: LayoutElement.SpannerKind, lineProperties: Spanner.LineProperties?, endText: String?,
        placedBelow: Bool, metrics: StaffMetrics,
    ) -> LayoutLineDetail? {
        // A wedge is two strokes of its own, but its end text rides here like every other line's.
        if kind == .hairpinOpen || kind == .hairpinClose {
            return LayoutLineDetail(
                endRichText: typesetLineLabel(endText, kind: kind, metrics: metrics),
                placedBelow: placedBelow, labelAlignment: .center,
            )
        }
        guard let base = TextLineBaseStyle.style(for: kind) else { return nil }
        let props = lineProperties ?? Spanner.LineProperties()
        let width = props.lineWidth ?? base.lineWidthSp
        return LayoutLineDetail(
            endRichText: typesetLineLabel(endText, kind: kind, metrics: metrics),
            beginHook: props.beginHook ?? .none,
            endHook: props.endHook ?? base.defaultEndHook,
            beginHookHeightSp: props.beginHookHeight ?? base.hookHeightSp,
            endHookHeightSp: props.endHookHeight ?? base.hookHeightSp,
            lineVisible: props.lineVisible ?? true,
            lineType: props.lineType ?? base.lineType,
            lineWidthSp: width,
            dashSp: (props.dashLength ?? base.dashLineWidths) * width,
            gapSp: (props.dashGap ?? base.gapLineWidths) * width,
            placedBelow: placedBelow,
            labelAlignment: base.labelAlignment,
        )
    }
}
