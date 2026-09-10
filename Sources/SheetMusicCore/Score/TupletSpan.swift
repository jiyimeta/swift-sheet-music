import SheetMusicFoundation

/// A positional view computed from a voice's raw tuplet endpoints. Dangling references resolve to -1.
public struct TupletSpan: Sendable, Equatable {
    public var normalNotes: Int
    public var actualNotes: Int
    public var startIndex: Int
    public var endIndex: Int

    public init(normalNotes: Int, actualNotes: Int, startIndex: Int, endIndex: Int) {
        self.normalNotes = normalNotes
        self.actualNotes = actualNotes
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}
