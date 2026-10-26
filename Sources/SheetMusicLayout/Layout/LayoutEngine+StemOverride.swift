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
    /// notes' positions (`ChordLayout::computeUp`), or nil. A two-note tremolo's chords take none: MuseScore lays the
    /// pair out together whatever either says. A beamed chord's stem is its beam's (`beamDirection`).
    static func stemOverride(ofChordAt index: Int, in elements: [VoiceElement]) -> StemDirection? {
        guard case let .chord(chord) = elements[index], let direction = chord.stemDirection,
              chord.tremolo?.span != .between
        else { return nil }
        // The second chord of a two-note tremolo carries no tremolo; the chord before it does.
        let partner = elements[..<index].reversed().lazy.compactMap { element -> Chord? in
            if case let .chord(previous) = element { previous } else { nil }
        }.first
        guard partner?.tremolo?.span != .between else { return nil }
        return StemDirection(direction)
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
