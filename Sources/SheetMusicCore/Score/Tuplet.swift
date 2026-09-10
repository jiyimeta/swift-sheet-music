import SheetMusicFoundation

/// Literal endpoints are resolved at score adoption or a replacement payload's landing apply.
public enum TupletEndpoint: Sendable, Hashable {
    case index(Int)
    case element(EID)

    public func index(in elements: IdentifiedArray<VoiceElement>) -> Int {
        switch self {
        case let .index(index): index
        case let .element(eid): elements.index(of: eid) ?? -1
        }
    }

    func resolved(in elements: IdentifiedArray<VoiceElement>) -> Self {
        switch self {
        case let .index(index):
            precondition(elements.indices.contains(index), "tuplet endpoint outside its voice")
            return .element(elements.eid(at: index))
        case .element:
            return self
        }
    }
}

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
    public var first: TupletEndpoint
    public var last: TupletEndpoint

    public init(
        normalNotes: Int,
        actualNotes: Int,
        startIndex: Int,
        endIndex: Int,
    ) {
        self.init(normalNotes: normalNotes, actualNotes: actualNotes, first: .index(startIndex), last: .index(endIndex))
    }

    public init(normalNotes: Int, actualNotes: Int, first: EID, last: EID) {
        self.init(normalNotes: normalNotes, actualNotes: actualNotes, first: .element(first), last: .element(last))
    }

    public init(normalNotes: Int, actualNotes: Int, first: TupletEndpoint, last: TupletEndpoint) {
        self.normalNotes = normalNotes
        self.actualNotes = actualNotes
        self.first = first
        self.last = last
    }
}
