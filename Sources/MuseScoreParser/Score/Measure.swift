import Foundation

/// A measure (bar) made up of one or more `Voice`s. C++: `mu::engraving::Measure`.
public struct Measure: Sendable, Equatable {
    public var voices: [Voice]
    /// True when this measure starts a repeat (`<startRepeat/>` in mscx).
    public var startRepeat: Bool
    /// Number of plays when this measure ends a repeat (`<endRepeat>N</endRepeat>`).
    /// `nil` means no end-of-repeat marker on this measure.
    public var endRepeatCount: Int?

    public init(
        voices: [Voice],
        startRepeat: Bool = false,
        endRepeatCount: Int? = nil
    ) {
        self.voices = voices
        self.startRepeat = startRepeat
        self.endRepeatCount = endRepeatCount
    }
}
