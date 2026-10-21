import SheetMusicCore
import SheetMusicFoundation

/// Both `<location>`s of every tie MuseScore made into another voice of one staff (`CrossVoiceTies`), filed by where
/// each note sits: measure, then voice, then element, then note.
///
/// The voice walker works a tie's `<location>` out from its own neighbours — the next or previous chord of the same
/// voice — which names the wrong chord for such a tie, so MuseScore found no partner there and dropped it when it
/// opened a file this package wrote. These endpoints are what MuseScore itself writes: the partner's voice as
/// `<voices>`, its bar as `<measures>`, its position within that bar relative to this chord's as `<fractions>`.
struct MSCXCrossVoiceTieEndpoints {
    /// The two sides one note can carry.
    struct Ends {
        var forward: TieEndpoint?
        var back: TieEndpoint?
    }

    /// Voice → element → note, for the notes of one measure.
    typealias MeasureEnds = [Int: [Int: [Int: Ends]]]

    private var byMeasure: [Int: MeasureEnds] = [:]

    init(measures: [Measure]) {
        for link in CrossVoiceTies.links(in: measures) {
            guard let fromNotes = Self.notes(at: link.from, in: measures),
                  let toNotes = Self.notes(at: link.to, in: measures),
                  fromNotes.indices.contains(link.from.note), toNotes.indices.contains(link.to.note)
            else { continue }
            let notesDelta = MSCXLocationNoteIndex.index(ofPitch: toNotes[link.to.note].pitch, in: toNotes)
                - MSCXLocationNoteIndex.index(ofPitch: fromNotes[link.from.note].pitch, in: fromNotes)
            let voicesDelta = link.to.voice - link.from.voice
            set(\.forward, at: link.from, to: TieEndpoint(
                Self.location(from: (link.from.measure, link.fromOffset), to: (link.to.measure, link.toOffset)),
                notesDelta: notesDelta, voicesDelta: voicesDelta,
            ))
            set(\.back, at: link.to, to: TieEndpoint(
                Self.location(from: (link.to.measure, link.toOffset), to: (link.from.measure, link.fromOffset)),
                notesDelta: -notesDelta, voicesDelta: -voicesDelta,
            ))
        }
    }

    /// The endpoints of the notes of measure `index`, empty for a measure no cross-voice tie touches.
    func forMeasure(_ index: Int) -> MeasureEnds {
        byMeasure[index] ?? [:]
    }

    private mutating func set(
        _ side: WritableKeyPath<Ends, TieEndpoint?>, at end: CrossVoiceTies.End, to value: TieEndpoint,
    ) {
        byMeasure[end.measure, default: [:]][end.voice, default: [:]][end.element, default: [:]][
            end.note, default: Ends(),
        ][keyPath: side] = value
    }

    /// `<measures>` and `<fractions>` from one end's chord to the other's, eliding a zero fraction as MuseScore does.
    private static func location(
        from source: (measure: Int, offset: Fraction), to target: (measure: Int, offset: Fraction),
    ) -> TieLocation {
        let fractions = target.offset - source.offset
        if target.measure == source.measure {
            return .sameMeasure(fractions: fractions)
        }
        return .crossMeasure(
            measures: target.measure - source.measure, fractions: fractions.numerator == 0 ? nil : fractions,
        )
    }

    private static func notes(at end: CrossVoiceTies.End, in measures: [Measure]) -> ChordNotes? {
        guard measures.indices.contains(end.measure),
              measures[end.measure].voices.indices.contains(end.voice),
              measures[end.measure].voices[end.voice].elements.indices.contains(end.element),
              case let .chord(chord) = measures[end.measure].voices[end.voice].elements[end.element]
        else { return nil }
        return chord.notes
    }
}
