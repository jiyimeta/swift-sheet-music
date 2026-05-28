#if canImport(CoreGraphics)
    import CoreGraphics
#endif

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

/// Visibility for `<LayoutBreak>` indicator badges drawn over the
/// on-screen score. Independent from `LayoutBreakPolicy` — this enum
/// only hides badges that would otherwise be drawn; layout behavior
/// is unchanged.
public enum BreakIndicatorVisibility: Sendable, Equatable {
    /// Show both line- and page-break badges.
    case all
    /// Hide line-break badges; still show page-break badges.
    case pageOnly
    /// Hide all break indicator badges.
    case none
}

/// Policy for collapsing runs of consecutive rest measures into a
/// single multi-measure-rest bar (the H-bar + count notation).
/// Affects layout only — `Score` and MIDI are untouched.
public enum MultiMeasureRestPolicy: Sendable, Equatable {
    /// Default — every rest measure renders individually.
    case disabled

    /// Collapse runs of `>= minimumMeasures` consecutive rest
    /// measures into one H-bar. Typical value is 2. Values < 2 are
    /// clamped to 2 by the planner.
    case collapse(minimumMeasures: Int)
}

/// Tunable knobs for `ScoreView`. v1 intentionally keeps this small —
/// layout is driven by the view's available width and these values.
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
    /// Which `<LayoutBreak>` indicator badges to draw over each
    /// system as authoring hints. Default `.all` matches behavior
    /// from before this option existed. Has no effect on PDF
    /// export — `PDFExporter` always passes `.none`.
    public var breakIndicatorVisibility: BreakIndicatorVisibility
    /// Visual scale factor applied to grace-note glyphs (notehead +
    /// stem + flag) relative to a main chord. MuseScore's
    /// `Sid::graceNoteMag` default is 0.7; we use 0.6 to stay
    /// closer to the historical "Petrucci" look used in Bravura.
    public var graceNoteMag: CGFloat
    /// Multi-measure rest collapse policy. Default `.disabled` matches
    /// pre-existing behavior — every rest measure renders individually.
    public var multiMeasureRest: MultiMeasureRestPolicy
    /// MuseScore "Show Invisible". When true, elements with
    /// `visible == false` are still laid out and tagged invisible so
    /// renderers grey them (`#808080` on white = 50% opacity). When
    /// false (print behaviour, the default), invisible elements are
    /// dropped entirely.
    ///
    /// **Coverage** — element families and how this toggle applies:
    ///
    /// - **Fully honoured (visible+invisible routing, slot preserved):**
    ///   `Tempo`, `StaffText`, `Swing`, `Harmony`, `Clef`,
    ///   `KeySignature`, `TimeSignature`, `BarLine`, `Dynamic`,
    ///   `Fermata`, `Lyric` (per-verse), `RehearsalMark`,
    ///   per-`Note` within a visible chord, `Arpeggio`.
    /// - **Partial — whole chord/rest visibility:**
    ///   `Chord.visible == false` round-trips through MSCX but the
    ///   layout currently does NOT route the chord to the invisible
    ///   container (per-note `Note.visible` IS handled). Hidden
    ///   chords therefore render unchanged regardless of the toggle.
    ///   Tracked as follow-up.
    /// - **Partial — spanners:**
    ///   `Spanner.visible == false` round-trips, and layout drops
    ///   hidden spanners. The invisible-container routing (so toggle-on
    ///   greys them) is not yet wired. Tracked as follow-up.
    /// - **Out of scope:**
    ///   MusicXML's `print-object="no"` is not yet ingested into
    ///   `ElementProperties.visible`. MIDI is unaffected by visibility
    ///   regardless of the toggle — `Note.play` governs playback.
    ///
    /// Default: `false` (print behaviour).
    public var showsInvisibleElements: Bool

    public init(
        staffSize: CGFloat = 28,
        systemGap: CGFloat = 40,
        wrapToViewWidth: Bool = true,
        includeTitleFrame: Bool = true,
        breakPolicy: LayoutBreakPolicy = .honor,
        breakIndicatorVisibility: BreakIndicatorVisibility = .all,
        graceNoteMag: CGFloat = 0.6,
        multiMeasureRest: MultiMeasureRestPolicy = .disabled,
        showsInvisibleElements: Bool = false,
    ) {
        self.staffSize = staffSize
        self.systemGap = systemGap
        self.wrapToViewWidth = wrapToViewWidth
        self.includeTitleFrame = includeTitleFrame
        self.breakPolicy = breakPolicy
        self.breakIndicatorVisibility = breakIndicatorVisibility
        self.graceNoteMag = graceNoteMag
        self.multiMeasureRest = multiMeasureRest
        self.showsInvisibleElements = showsInvisibleElements
    }
}
