import Foundation

/// A tuplet marking inside a voice (triplet, quintuplet, septuplet, …).
/// C++: `mu::engraving::Tuplet` (subset — we only carry what's needed
/// to draw the bracket/number, not the playback scaling which is
/// already baked into each member's `NoteDuration`).
public struct Tuplet: Sendable, Equatable {
    /// "in the time of N normal notes" — numerator of the MSCX ratio.
    public var normalNotes: Int
    /// "N actual notes" — denominator of the MSCX ratio, and the
    /// number shown above/below the bracket.
    public var actualNotes: Int
    /// Index of the first member in `Voice.elements`.
    public var startIndex: Int
    /// Index of the last member in `Voice.elements` (inclusive).
    public var endIndex: Int

    public init(
        normalNotes: Int,
        actualNotes: Int,
        startIndex: Int,
        endIndex: Int
    ) {
        self.normalNotes = normalNotes
        self.actualNotes = actualNotes
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}
