#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Outer whitespace around engraved music, measured in staff spaces (sp).
///
/// `LayoutEngine.layout` treats `availableWidth` as the width offered to the
/// music itself and adds these margins outside it. The document may therefore
/// be wider than `availableWidth`; the standard 2 sp trailing margin already
/// behaved this way before the value was named by this option. A host that
/// needs the document to fit a container should subtract its margins from the
/// supplied `availableWidth`, or use `ScoreViewOptions.fixedLayoutWidth`.
///
/// Margins deliberately do not affect wrapping. This keeps system breaks
/// stable when a host changes only the surrounding whitespace.
public struct EngravingMargins: Sendable, Equatable {
    /// Top margin in sp. Analogous to MuseScore's
    /// `Sid::pageOddTopMargin` / `Sid::pageEvenTopMargin`; increasing it
    /// moves the title block and every system downward.
    public var top: CGFloat = 0
    /// Leading margin in sp. Analogous to MuseScore's
    /// `Sid::pageOddLeftMargin` / `Sid::pageEvenLeftMargin`; increasing it
    /// moves every system toward the trailing edge.
    public var leading: CGFloat = 0
    /// Bottom margin in sp. Analogous to MuseScore's
    /// `Sid::pageOddBottomMargin` / `Sid::pageEvenBottomMargin`; increasing
    /// it adds whitespace below the last system.
    public var bottom: CGFloat = 0
    /// Trailing margin in sp. MuseScore derives the corresponding page edge
    /// from its left margin and `Sid::pagePrintableWidth`; increasing it adds
    /// whitespace after the widest system without moving the music.
    public var trailing: CGFloat = 2

    public init(
        top: CGFloat = 0,
        leading: CGFloat = 0,
        bottom: CGFloat = 0,
        trailing: CGFloat = 2,
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

/// Host-overridable engraving distances. Values are in staff spaces (sp)
/// except `systemStretch`, which is a unitless ratio.
public struct EngravingSpacing: Sendable, Equatable {
    /// Minimum distance between adjacent note columns, in sp. Corresponds to
    /// MuseScore's `Sid::minNoteDistance`; increasing it opens up tightly
    /// subdivided neighboring note columns.
    public var minNoteDistance: CGFloat = 0
    /// Horizontal advance per quarter note, in sp. Calibrated against
    /// MuseScore's `Sid::measureSpacing`; increasing it widens rhythm-driven
    /// measure spacing before system stretch.
    public var spacePerQuarter: CGFloat = 1.6
    /// Natural system stretch as a unitless ratio. There is no direct
    /// MuseScore `Sid::` counterpart; it controls how readily wrapped systems
    /// close and the breathing room applied to horizontal no-wrap layouts.
    public var systemStretch: CGFloat = 1.5
    /// Outer document margins, in sp. See `EngravingMargins` for the related
    /// MuseScore `Sid::` values and their visible effects.
    public var margins: EngravingMargins = .init()
    /// First-system label-width floor, in sp. Corresponds to MuseScore's
    /// `Sid::firstSystemIndent`; increasing it moves the first staff right
    /// when instrument labels and bracket gutters need less room.
    public var firstSystemIndent: CGFloat = 4
    /// Continuation-system label-width floor, in sp. There is no direct
    /// MuseScore `Sid::` counterpart; increasing it moves later systems'
    /// staves right when their short labels need less room.
    public var continuationSystemIndent: CGFloat = 2
    /// Floor on the gap between adjacent staves within one system, in sp.
    ///
    /// NOT the whole staff distance. The engine assembles that from the
    /// previous staff's south-skyline pad (2.5 sp or more, growing with
    /// lyrics and dynamics), this floor, and the next staff's 2 sp top
    /// baseline — about 5 sp together, which is what approximates
    /// MuseScore's `Sid::staffDistance = 6.5 sp`. This value only raises
    /// the floor, so lowering it below the default frees nothing on a
    /// staff whose skyline already exceeds it.
    public var minStaffGap: CGFloat = 0.5
    /// Padding above and below each system, in sp. It plays the local role of
    /// MuseScore's `Sid::staffUpperBorder` / `Sid::staffLowerBorder`;
    /// increasing it makes every system taller.
    public var systemVerticalPadding: CGFloat = 1

    public init(
        minNoteDistance: CGFloat = 0,
        spacePerQuarter: CGFloat = 1.6,
        systemStretch: CGFloat = 1.5,
        margins: EngravingMargins = .init(),
        firstSystemIndent: CGFloat = 4,
        continuationSystemIndent: CGFloat = 2,
        minStaffGap: CGFloat = 0.5,
        systemVerticalPadding: CGFloat = 1,
    ) {
        self.minNoteDistance = minNoteDistance
        self.spacePerQuarter = spacePerQuarter
        self.systemStretch = systemStretch
        self.margins = margins
        self.firstSystemIndent = firstSystemIndent
        self.continuationSystemIndent = continuationSystemIndent
        self.minStaffGap = minStaffGap
        self.systemVerticalPadding = systemVerticalPadding
    }

    /// Spacing values that reproduce the layout engine's historical output.
    public static let standard = EngravingSpacing()
}
