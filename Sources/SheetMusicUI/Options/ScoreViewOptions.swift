import CoreGraphics

/// Tunable knobs for `ScoreView`. v1 intentionally keeps this small —
/// layout is driven by the view's available width and these three values.
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

    public init(
        staffSize: CGFloat = 28,
        systemGap: CGFloat = 40,
        wrapToViewWidth: Bool = true,
        includeTitleFrame: Bool = true
    ) {
        self.staffSize = staffSize
        self.systemGap = systemGap
        self.wrapToViewWidth = wrapToViewWidth
        self.includeTitleFrame = includeTitleFrame
    }
}
