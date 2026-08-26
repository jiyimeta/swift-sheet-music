import SheetMusicFoundation

/// Time-ordered sequence of elements within a measure. C++: `mu::engraving::Voice`.
public struct Voice: Sendable, Equatable {
    public var elements: [VoiceElement]
    /// Tuplet spans within this voice. Each entry's `startIndex` /
    /// `endIndex` index into `elements`.
    public var tuplets: [Tuplet]

    public init(
        elements: [VoiceElement],
        tuplets: [Tuplet] = [],
    ) {
        self.elements = elements
        self.tuplets = tuplets
    }
}
