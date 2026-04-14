import Foundation

/// Clef change. Display-only — does not affect MIDI output.
/// C++: `mu::engraving::Clef`.
public struct Clef: Sendable, Equatable {
    public var concertClefType: String
    public var transposingClefType: String?

    public init(concertClefType: String, transposingClefType: String? = nil) {
        self.concertClefType = concertClefType
        self.transposingClefType = transposingClefType
    }
}
