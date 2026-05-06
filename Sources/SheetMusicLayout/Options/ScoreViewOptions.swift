import CoreGraphics

/// Policy for honoring authored `<LayoutBreak>` markup at display time.
///
/// MuseScore stores explicit line / page breaks on each measure; this
/// enum lets callers selectively ignore them when wrapping a score
/// authored for a different page size or aggregating into a
/// continuous-flow reader. The score model is unchanged — only how
/// the layout / pagination / overlay code consumes the flags.
///
/// | policy                | line→system | page→system | page→page-close |
/// | `.honor`              | yes         | yes         | yes             |
/// | `.ignoreSystemBreaks` | no          | yes         | yes             |
/// | `.ignoreAll`          | no          | no          | no              |
@available(macOS 15.0, iOS 16.0, *)
public enum LayoutBreakPolicy: Sendable, Equatable {
    /// Default — `<LayoutBreak>line` and `<LayoutBreak>page` both
    /// force a new system; `<LayoutBreak>page` additionally closes
    /// the current page. Equivalent to behavior prior to this option.
    case honor

    /// Ignore `<LayoutBreak>line`. `<LayoutBreak>page` still forces
    /// both a system break and a page close (a page break implies a
    /// system break in MuseScore's model — see
    /// `engraving/rendering/score/systemlayout.cpp:262`).
    case ignoreSystemBreaks

    /// Ignore both `<LayoutBreak>line` and `<LayoutBreak>page`. The
    /// engine wraps purely on available width; the paginator only
    /// closes pages on vertical overflow.
    case ignoreAll
}

/// Tunable knobs for `ScoreView`. v1 intentionally keeps this small —
/// layout is driven by the view's available width and these values.
@available(macOS 15.0, iOS 16.0, *)
public struct ScoreViewOptions: Sendable, Equatable {
    /// Height of one five-line staff in points. Defaults to 28 pt
    /// (roughly rastral 3).
    public var staffSize: CGFloat
    /// Vertical gap between systems (lines of music) in points.
    public var systemGap: CGFloat
    /// When true, measures wrap to the view's available width.
    /// When false, the layout emits a single long system and the caller is
    /// expected to wrap the `ScoreView` in a `ScrollView(.horizontal)`.
    public var wrapToViewWidth: Bool
    /// When true, the layout reserves space for `Score.titleFrame`
    /// (a `<VBox>` in MuseScore) above the first system and the
    /// renderer paints title / subtitle / composer text inside it.
    /// Off by default for the horizontal scroll layout, where a
    /// page-style title block doesn't fit the editing flow.
    public var includeTitleFrame: Bool
    /// How to consume authored `<LayoutBreak>` markup. Default
    /// `.honor` reproduces behavior from before this option existed.
    public var breakPolicy: LayoutBreakPolicy

    public init(
        staffSize: CGFloat = 28,
        systemGap: CGFloat = 40,
        wrapToViewWidth: Bool = true,
        includeTitleFrame: Bool = true,
        breakPolicy: LayoutBreakPolicy = .honor
    ) {
        self.staffSize = staffSize
        self.systemGap = systemGap
        self.wrapToViewWidth = wrapToViewWidth
        self.includeTitleFrame = includeTitleFrame
        self.breakPolicy = breakPolicy
    }
}
