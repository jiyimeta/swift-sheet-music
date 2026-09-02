import SheetMusicFoundation

extension Measure {
    /// The measure-level fields MuseScore writes on the first staff only (`writeSystemElements`): the layout
    /// breaks, the navigation markers and jumps, and the repeat flags. Grouped so they move as one unit when the
    /// canonical staff changes (`MeasureFlagsHoist`) and hash as one unit (`FNV1a.combineFlags`).
    ///
    /// `measureRepeatCount` is NOT here: a measure repeat is per staff, so it stays with its staff.
    public struct Flags: Sendable, Equatable {
        public var lineBreak: Bool
        public var pageBreak: Bool
        public var sectionBreak: Bool
        public var startRepeat: Bool
        public var endRepeatCount: Int?
        public var markers: [Marker]
        public var jumps: [Jump]

        public init(
            lineBreak: Bool = false, pageBreak: Bool = false, sectionBreak: Bool = false,
            startRepeat: Bool = false, endRepeatCount: Int? = nil,
            markers: [Marker] = [], jumps: [Jump] = [],
        ) {
            self.lineBreak = lineBreak
            self.pageBreak = pageBreak
            self.sectionBreak = sectionBreak
            self.startRepeat = startRepeat
            self.endRepeatCount = endRepeatCount
            self.markers = markers
            self.jumps = jumps
        }

        public static let none = Flags()

        public var isEmpty: Bool {
            self == .none
        }
    }

    public var flags: Flags {
        get {
            Flags(
                lineBreak: lineBreak, pageBreak: pageBreak, sectionBreak: sectionBreak,
                startRepeat: startRepeat, endRepeatCount: endRepeatCount, markers: markers, jumps: jumps,
            )
        }
        set {
            lineBreak = newValue.lineBreak
            pageBreak = newValue.pageBreak
            sectionBreak = newValue.sectionBreak
            startRepeat = newValue.startRepeat
            endRepeatCount = newValue.endRepeatCount
            markers = newValue.markers
            jumps = newValue.jumps
        }
    }
}
