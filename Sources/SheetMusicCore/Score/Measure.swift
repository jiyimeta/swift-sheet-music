import SheetMusicFoundation

/// A measure (bar) made up of one or more `Voice`s. C++: `mu::engraving::Measure`.
public struct Measure: Sendable, Equatable {
    public var voices: [Voice]
    /// True when this measure starts a repeat (`<startRepeat/>` in mscx).
    public var startRepeat: Bool
    /// Number of plays when this measure ends a repeat (`<endRepeat>N</endRepeat>`).
    /// `nil` means no end-of-repeat marker on this measure.
    public var endRepeatCount: Int?
    /// `<measureRepeatCount>N</measureRepeatCount>`: this measure is the Nth one of
    /// a multi-measure-repeat group. N=1 marks the group's first measure (which
    /// also contains the explicit `<MeasureRepeat>` element); N=2 marks the second
    /// (continuation) member of a 2-measure repeat group, and so on.
    public var measureRepeatCount: Int?
    /// Measure-left `<Marker>` entries (Segno, Coda, Fine, To Coda).
    public var markers: [Marker]
    /// Measure-right `<Jump>` entries (D.C., D.S., D.C. al Coda, …).
    public var jumps: [Jump]
    /// `<LayoutBreak><subtype>line</subtype>`. When `true`, the next
    /// measure starts a new system. Mirrors
    /// `MeasureBase::lineBreak()` (`engraving/dom/measurebase.h:140`)
    /// and the system-break check in
    /// `engraving/rendering/score/systemlayout.cpp:262`.
    public var lineBreak: Bool
    /// `<LayoutBreak><subtype>page</subtype>`. When `true`, the next
    /// measure starts a new page (and, transitively, a new system).
    /// Mirrors `MeasureBase::pageBreak()` —
    /// `engraving/rendering/score/systemlayout.cpp:262` treats
    /// `pageBreak()` as ALSO triggering a line break.
    public var pageBreak: Bool
    /// `<LayoutBreak><subtype>section</subtype>`. When `true`, this
    /// measure ends a *section*: playback navigation state (repeat
    /// unrolling, jump `findMarker` scope) resets at the boundary.
    /// Mirrors `MeasureBase::sectionBreak()`
    /// (`engraving/dom/measurebase.h`) as consumed by
    /// `RepeatList::collectRepeatListElements`
    /// (`engraving/dom/repeatlist.cpp:647`).
    public var sectionBreak: Bool
    /// `<Measure len="N/D">` — actual measure length when it differs from
    /// the prevailing time signature. `nil` means "follow the time
    /// signature". Mirrors `Measure::ticks()` vs `nominalTicks()` in
    /// MuseScore.
    public var actualLength: Fraction?
    /// `<irregular>1</irregular>` — exclude this measure from the running
    /// displayed measure number. Typically set on an anacrusis.
    public var irregular: Bool

    public init(
        voices: [Voice],
        startRepeat: Bool = false,
        endRepeatCount: Int? = nil,
        measureRepeatCount: Int? = nil,
        markers: [Marker] = [],
        jumps: [Jump] = [],
        lineBreak: Bool = false,
        pageBreak: Bool = false,
        sectionBreak: Bool = false,
        actualLength: Fraction? = nil,
        irregular: Bool = false,
    ) {
        self.voices = voices
        self.startRepeat = startRepeat
        self.endRepeatCount = endRepeatCount
        self.measureRepeatCount = measureRepeatCount
        self.markers = markers
        self.jumps = jumps
        self.lineBreak = lineBreak
        self.pageBreak = pageBreak
        self.sectionBreak = sectionBreak
        self.actualLength = actualLength
        self.irregular = irregular
    }
}
