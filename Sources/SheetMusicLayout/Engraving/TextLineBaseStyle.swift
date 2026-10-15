import SheetMusicCore

/// The defaults a `TextLineBase` spanner draws with when the file overrides nothing, per kind (all `styledef.cpp`
/// unless noted). `nil` properties of `Spanner.LineProperties` resolve to these at layout time.
struct TextLineBaseStyle: Equatable {
    /// In spatia.
    var lineWidthSp: Double
    var lineType: Spanner.LineType
    /// Dash length and gap in line widths.
    var dashLineWidths: Double
    var gapLineWidths: Double
    /// Begin and end hook height, in spatia.
    var hookHeightSp: Double
    var defaultEndHook: Spanner.LineHookType
    var labelAlignment: LabelAlignment

    /// Pedal: `pedalLineWidth` 0.11 (:319), `pedalLineStyle` SOLID (:320), `pedalDashLineLen/GapLen` 4/4 (:321-322),
    /// `pedalHookHeight` 1.2 (:323), `pedalTextAlign` LEFT/BASELINE (:331). `Pedal` has no end-hook style: NONE.
    private static let pedal = TextLineBaseStyle(
        lineWidthSp: 0.11, lineType: .solid, dashLineWidths: 4, gapLineWidths: 4, hookHeightSp: 1.2,
        defaultEndHook: .none, labelAlignment: .baseline,
    )

    /// Text line: `textLineLineWidth` 0.15 (:774), `textLineLineStyle` SOLID (:775), `textLineDashLineLen/GapLen`
    /// 4/4 (:776-777), `textLineHookHeight` 1.5 (:778), `textLineTextAlign` LEFT/VCENTER (:1454); hooks NONE
    /// (`dom/textline.cpp:173-176`).
    private static let textLine = TextLineBaseStyle(
        lineWidthSp: 0.15, lineType: .solid, dashLineWidths: 4, gapLineWidths: 4, hookHeightSp: 1.5,
        defaultEndHook: .none, labelAlignment: .center,
    )

    /// Hairpin line (`CRESC_LINE` / `DIM_LINE`): `hairpinLineWidth` 0.12 (:288), `hairpinLineLineStyle` DASHED
    /// (:311), `hairpinLineDashLineLen/GapLen` 6/9 (:312-313), `hairpinTextAlign` LEFT/BASELINE (:295); the hook
    /// height is the `TextLineBase` constructor's 1.9 (`dom/textlinebase.cpp:215-222`), hooks NONE.
    private static let hairpinLine = TextLineBaseStyle(
        lineWidthSp: 0.12, lineType: .dashed, dashLineWidths: 6, gapLineWidths: 9, hookHeightSp: 1.9,
        defaultEndHook: .none, labelAlignment: .baseline,
    )

    /// Let ring: `letRingLineWidth` 0.11 (:1887), `letRingLineStyle` DASHED (:1888), `letRingDashLineLen/GapLen` 5/5
    /// (:1889-1890), `letRingHookHeight` 0.6 (:1883), `letRingEndHookType` HOOK_90T (:1899), `letRingTextAlign`
    /// LEFT/VCENTER (:1882). Harmonic mark and rasgueado read exactly these Sids (`dom/harmonicmark.cpp:34-61`,
    /// `dom/rasgueado.cpp:34-61`).
    private static let letRing = TextLineBaseStyle(
        lineWidthSp: 0.11, lineType: .dashed, dashLineWidths: 5, gapLineWidths: 5, hookHeightSp: 0.6,
        defaultEndHook: .hook90T, labelAlignment: .center,
    )

    /// Palm mute: `palmMuteLineWidth` 0.11 (:1939), `palmMuteLineStyle` DASHED (:1940), `palmMuteDashLineLen/GapLen`
    /// 5/5 (:1941-1942), `palmMuteHookHeight` 0.6 (:1935), `palmMuteEndHookType` HOOK_90T (:1951),
    /// `palmMuteTextAlign` LEFT/VCENTER (:1934). Pick scrape reads these Sids (`dom/pickscrape.cpp:34-61`).
    private static let palmMute = TextLineBaseStyle(
        lineWidthSp: 0.11, lineType: .dashed, dashLineWidths: 5, gapLineWidths: 5, hookHeightSp: 0.6,
        defaultEndHook: .hook90T, labelAlignment: .center,
    )

    /// Whammy bar: `whammyBarLineWidth` 0.11 (:1913), `whammyBarLineStyle` DASHED (:1914), `whammyBarDashLineLen/
    /// GapLen` 5/5 (:1915-1916), `whammyBarHookHeight` 0.6 (:1909), `whammyBarEndHookType` HOOK_90T (:1925),
    /// `whammyBarTextAlign` LEFT/VCENTER (:1908).
    private static let whammyBar = TextLineBaseStyle(
        lineWidthSp: 0.11, lineType: .dashed, dashLineWidths: 5, gapLineWidths: 5, hookHeightSp: 0.6,
        defaultEndHook: .hook90T, labelAlignment: .center,
    )

    /// The style of a text-line-family kind; `nil` for a kind that is not drawn by `SpannerGeometry.textLineBase`.
    static func style(for kind: LayoutElement.SpannerKind) -> TextLineBaseStyle? {
        switch kind {
        case .pedal: pedal
        case .textLine: textLine
        case .hairpinLine: hairpinLine
        case .letRing: letRing
        case .palmMute: palmMute
        case let .chordTextLine(line):
            switch line {
            case .harmonicMark, .rasgueado: letRing
            case .pickScrape: palmMute
            case .whammyBar: whammyBar
            }
        case .slur, .volta, .hairpinOpen, .hairpinClose, .ottava, .vibrato, .trill, .gradualTempoChange: nil
        }
    }
}
