import SheetMusicCore

/// Which edge of a line label sits on the label's anchor y: its first baseline (pedal, hairpin line) or its vertical
/// center (text line, let ring, palm mute, whammy bar).
public enum LabelAlignment: Sendable, Equatable {
    case baseline
    case center
}

/// What a line spanner segment draws beside its begin label: the end label, the hooks, and the line's own visibility,
/// type and size, resolved with the kind's defaults at layout time.
public struct LayoutLineDetail: Sendable, Equatable {
    /// The label at the line's end; only the segment that ends the line carries one.
    public var endRichText: LayoutRichText?
    public var beginHook: Spanner.LineHookType
    public var endHook: Spanner.LineHookType
    /// In spatia.
    public var beginHookHeightSp: Double
    public var endHookHeightSp: Double
    public var lineVisible: Bool
    public var lineType: Spanner.LineType
    /// In spatia.
    public var lineWidthSp: Double
    /// Dash and gap already multiplied by the line width, in spatia.
    public var dashSp: Double
    public var gapSp: Double
    public var placedBelow: Bool
    public var labelAlignment: LabelAlignment

    public init(
        endRichText: LayoutRichText? = nil,
        beginHook: Spanner.LineHookType = .none,
        endHook: Spanner.LineHookType = .none,
        beginHookHeightSp: Double = 0,
        endHookHeightSp: Double = 0,
        lineVisible: Bool = true,
        lineType: Spanner.LineType = .solid,
        lineWidthSp: Double = 0.15,
        dashSp: Double = 0,
        gapSp: Double = 0,
        placedBelow: Bool = false,
        labelAlignment: LabelAlignment = .center,
    ) {
        self.endRichText = endRichText
        self.beginHook = beginHook
        self.endHook = endHook
        self.beginHookHeightSp = beginHookHeightSp
        self.endHookHeightSp = endHookHeightSp
        self.lineVisible = lineVisible
        self.lineType = lineType
        self.lineWidthSp = lineWidthSp
        self.dashSp = dashSp
        self.gapSp = gapSp
        self.placedBelow = placedBelow
        self.labelAlignment = labelAlignment
    }
}
