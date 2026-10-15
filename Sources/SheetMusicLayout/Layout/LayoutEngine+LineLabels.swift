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
    /// carries. Only a volta draws typeset text there, and only an authored `<beginText>` (MuseScore has no automatic
    /// volta label).
    static func attachedLabelRuns(
        kind: LayoutElement.SpannerKind, anchor: SpannerAnchor, continuesLeft: Bool, metrics: StaffMetrics,
    ) -> LayoutRichText? {
        guard case .volta = kind else { return nil }
        return labelRuns(kind: kind, anchor: anchor, continuesLeft: continuesLeft, metrics: metrics)
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
        return typesetLineLabel(continuesLeft ? labels.continuation : labels.begin, metrics: metrics)
    }

    /// The kinds whose label is typeset text (a wedge, an ottava, a slur, a vibrato and a trill draw their own).
    private static func drawsLabelRuns(kind: LayoutElement.SpannerKind) -> Bool {
        switch kind {
        case .pedal, .textLine, .palmMute, .letRing, .chordTextLine, .hairpinLine, .volta: true
        case .slur, .hairpinOpen, .hairpinClose, .ottava, .vibrato, .trill, .gradualTempoChange: false
        }
    }

    /// MuseScore xml text as runs in the staff-text style (Edwin 10, symbols 10); `nil` for none or empty text.
    private static func typesetLineLabel(_ xmlText: String?, metrics: StaffMetrics) -> LayoutRichText? {
        guard let xmlText, !xmlText.isEmpty else { return nil }
        let rich = LayoutRichText(RichText(xmlText: xmlText), style: .staffText, metrics: metrics)
        return rich.lines.contains { !$0.runs.isEmpty } ? rich : nil
    }

    /// What a line segment draws beside its begin label, resolved with the kind's defaults; `nil` for a kind that is
    /// not a text-line family member. The end label rides only on the segment that ends the line.
    static func lineDetail(
        kind: LayoutElement.SpannerKind, anchor: SpannerAnchor, clip: SystemClip, metrics: StaffMetrics,
    ) -> LayoutLineDetail? {
        let end = clip.continuesRight ? nil : anchor.lineLabels?.end
        return lineDetailDefaults(
            kind: kind, lineProperties: anchor.lineProperties, endText: end,
            placedBelow: isBelowStaff(anchor: anchor), metrics: metrics,
        )
    }

    /// `lineDetail` without a `Score`: the hooks, visibility, line type, width and dash of `lineProperties` over the
    /// kind's defaults (`nil` properties are all defaults).
    static func lineDetailDefaults(
        kind: LayoutElement.SpannerKind, lineProperties: Spanner.LineProperties?, endText: String?,
        placedBelow: Bool, metrics: StaffMetrics,
    ) -> LayoutLineDetail? {
        guard let base = baseStyle(kind: kind) else { return nil }
        let props = lineProperties ?? Spanner.LineProperties()
        let width = props.lineWidth ?? base.widthSp
        return LayoutLineDetail(
            endRichText: typesetLineLabel(endText, metrics: metrics),
            beginHook: props.beginHook ?? .none,
            endHook: props.endHook ?? base.endHook,
            beginHookHeightSp: props.beginHookHeight ?? base.hookHeightSp,
            endHookHeightSp: props.endHookHeight ?? base.hookHeightSp,
            lineVisible: props.lineVisible ?? true,
            lineType: props.lineType ?? base.lineType,
            lineWidthSp: width,
            dashSp: (props.dashLength ?? base.dash) * width,
            gapSp: (props.dashGap ?? base.gap) * width,
            placedBelow: placedBelow,
            labelAlignment: base.alignment,
        )
    }

    /// The per-kind defaults of `TextLineBaseStyle` (Decisions table; Task 8 moves this table).
    private struct LineBaseStyle {
        var widthSp: Double
        var dash: Double
        var gap: Double
        var hookHeightSp: Double
        var endHook: Spanner.LineHookType
        var lineType: Spanner.LineType
        var alignment: LabelAlignment
    }

    private static func baseStyle(kind: LayoutElement.SpannerKind) -> LineBaseStyle? {
        switch kind {
        case .pedal: // styledef.cpp:313-323
            LineBaseStyle(
                widthSp: 0.11, dash: 4, gap: 4, hookHeightSp: 1.2, endHook: .none, lineType: .solid,
                alignment: .baseline,
            )
        case .hairpinLine: // styledef.cpp:288, 774-777; `TextLineBase` ctor
            LineBaseStyle(
                widthSp: 0.12, dash: 6, gap: 9, hookHeightSp: 1.9, endHook: .none, lineType: .dashed,
                alignment: .baseline,
            )
        case .textLine:
            LineBaseStyle(
                widthSp: 0.15, dash: 4, gap: 4, hookHeightSp: 1.5, endHook: .none, lineType: .solid,
                alignment: .center,
            )
        case .palmMute, .letRing, .chordTextLine: // styledef.cpp:1887-1890, 1913-1916, 1939-1942
            LineBaseStyle(
                widthSp: 0.11, dash: 5, gap: 5, hookHeightSp: 0.6, endHook: .hook90T, lineType: .dashed,
                alignment: .center,
            )
        case .slur, .volta, .hairpinOpen, .hairpinClose, .ottava, .vibrato, .trill, .gradualTempoChange: nil
        }
    }
}
