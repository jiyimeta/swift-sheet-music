import Foundation

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

    public init(
        voices: [Voice],
        startRepeat: Bool = false,
        endRepeatCount: Int? = nil,
        measureRepeatCount: Int? = nil,
        markers: [Marker] = [],
        jumps: [Jump] = [],
        lineBreak: Bool = false
    ) {
        self.voices = voices
        self.startRepeat = startRepeat
        self.endRepeatCount = endRepeatCount
        self.measureRepeatCount = measureRepeatCount
        self.markers = markers
        self.jumps = jumps
        self.lineBreak = lineBreak
    }
}
