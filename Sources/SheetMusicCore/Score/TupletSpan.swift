import SheetMusicFoundation

/// A positional view computed from a voice's raw tuplet endpoints. Dangling references resolve to -1.
public struct TupletSpan: Sendable, Equatable {
    public var normalNotes: Int
    public var actualNotes: Int
    public var startIndex: Int
    public var endIndex: Int
    /// The owning `Voice.tuplets` slot's identifier, carried alongside for the
    /// encoder's convenience. `.invalid` by default for every call site that
    /// only cares about the span's shape (nesting validation, onset math);
    /// `Voice.tupletSpans` is the one production caller that fills in the
    /// real value. Deliberately excluded from `==` below — like
    /// `IdentifiedArray`'s own ids, two spans that describe the same range
    /// must still compare equal regardless of identity, or `Voice`'s
    /// content-only equality (`lhs.tupletSpans == rhs.tupletSpans`) would
    /// start reporting equivalent voices unequal.
    public var eid: EID

    public init(normalNotes: Int, actualNotes: Int, startIndex: Int, endIndex: Int, eid: EID = .invalid) {
        self.normalNotes = normalNotes
        self.actualNotes = actualNotes
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.eid = eid
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.normalNotes == rhs.normalNotes
            && lhs.actualNotes == rhs.actualNotes
            && lhs.startIndex == rhs.startIndex
            && lhs.endIndex == rhs.endIndex
    }
}
