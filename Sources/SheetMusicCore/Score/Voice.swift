import SheetMusicFoundation

/// Time-ordered sequence of elements within a measure. C++: `mu::engraving::Voice`.
public struct Voice: Sendable, Equatable {
    public var elements: IdentifiedArray<VoiceElement>
    /// Identified markings whose endpoints refer to members of this voice.
    public var tuplets: IdentifiedArray<Tuplet>

    public init(
        elements: [VoiceElement],
        tuplets: [Tuplet] = [],
    ) {
        self.elements = IdentifiedArray(elements)
        self.tuplets = IdentifiedArray(tuplets)
    }

    public init(elements: IdentifiedArray<VoiceElement>, tuplets: [Tuplet] = []) {
        self.elements = elements
        self.tuplets = IdentifiedArray(tuplets)
    }

    public init(elements: [VoiceElement], tuplets: IdentifiedArray<Tuplet>) {
        self.elements = IdentifiedArray(elements)
        self.tuplets = tuplets
    }

    public init(elements: IdentifiedArray<VoiceElement>, tuplets: IdentifiedArray<Tuplet>) {
        self.elements = elements
        self.tuplets = tuplets
    }

    public var tupletSpans: [TupletSpan] {
        tuplets.indices.map { index in
            let tuplet = tuplets[index]
            return TupletSpan(
                normalNotes: tuplet.normalNotes, actualNotes: tuplet.actualNotes,
                startIndex: tuplet.first.index(in: elements), endIndex: tuplet.last.index(in: elements),
                eid: tuplets.eid(at: index),
            )
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.elements == rhs.elements && lhs.tupletSpans == rhs.tupletSpans
    }
}
