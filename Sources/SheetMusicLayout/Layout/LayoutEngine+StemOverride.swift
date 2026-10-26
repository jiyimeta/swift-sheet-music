import SheetMusicCore

extension StemDirection {
    init(_ direction: StemDirectionOverride) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        }
    }
}

extension LayoutEngine {
    /// The direction a chord sets for its own stem (`Chord.stemDirection`), which wins over the voice's side and the
    /// notes' positions (`ChordLayout::computeUp`), or nil. A two-note tremolo's chords share one: the first's, or
    /// else the second's (`TremoloLayout::calcIsUp`), on both. A beamed chord's stem is its beam's (`beamDirection`).
    static func stemOverride(ofChordAt index: Int, in elements: [VoiceElement]) -> StemDirection? {
        guard case let .chord(chord) = elements[index] else { return nil }
        if chord.tremolo?.span == .between {
            let follower = elements[(index + 1)...].lazy.compactMap(Self.chord).first
            return tremoloPairOverride(start: chord, follower: follower)
        }
        // The second chord of a two-note tremolo carries no tremolo; the chord before it does.
        if let start = elements[..<index].reversed().lazy.compactMap(Self.chord).first,
           start.tremolo?.span == .between
        {
            return tremoloPairOverride(start: start, follower: chord)
        }
        return chord.stemDirection.map(StemDirection.init)
    }

    /// The direction a two-note tremolo's pair takes from its chords: the first's, else the second's, else none
    /// (`TremoloLayout::calcIsUp`).
    static func tremoloPairOverride(start: Chord, follower: Chord?) -> StemDirection? {
        (start.stemDirection ?? follower?.stemDirection).map(StemDirection.init)
    }

    private static func chord(_ element: VoiceElement) -> Chord? {
        if case let .chord(chord) = element { chord } else { nil }
    }

    /// A beam group's direction (`BeamLayout::layout1`): one set on the beam (`Chord.beamStemDirection` — on the
    /// chord that leads it in a MuseScore file, taken from any member since the groups here are the layout's own)
    /// wins over every rule; then `forced`, the voice's side when the measure splits into voices; then, outside a
    /// split measure, the first member that sets its own stem (`findChordWithCustomStemDirection`); then the notes'
    /// positions, `automatic`.
    static func beamDirection(
        members: [Int], in elements: [VoiceElement], forced: StemDirection?, automatic: () -> StemDirection,
    ) -> StemDirection {
        let chords = members.compactMap { index -> Chord? in
            if case let .chord(chord) = elements[index] { chord } else { nil }
        }
        if let set = chords.lazy.compactMap(\.beamStemDirection).first { return StemDirection(set) }
        if let forced { return forced }
        if let own = chords.lazy.compactMap(\.stemDirection).first { return StemDirection(own) }
        return automatic()
    }
}
