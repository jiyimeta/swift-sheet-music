import Foundation

/// Arpeggio attached to a chord. Spreads the chord's notes in time.
/// C++: `mu::engraving::Arpeggio`.
public struct Arpeggio: Sendable, Equatable {
    /// Mscx subtype: 0=NORMAL, 1=UP, 2=DOWN, 3=UP_STRAIGHT, 4=DOWN_STRAIGHT, 5=BRACKET.
    public var subtype: Int
    /// `<timeStretch>` multiplier on the per-note offset. Defaults to 1.
    public var timeStretch: Double
    /// `<userLen1>` (currently unused by the renderer; mirrors the C++ field).
    public var userLen1: Double

    public init(subtype: Int, timeStretch: Double = 1.0, userLen1: Double = 0.0) {
        self.subtype = subtype
        self.timeStretch = timeStretch
        self.userLen1 = userLen1
    }

    /// True for ascending arpeggios (lowest note first); false for DOWN/DOWN_STRAIGHT.
    public var isAscending: Bool {
        subtype != 2 && subtype != 4
    }
}
