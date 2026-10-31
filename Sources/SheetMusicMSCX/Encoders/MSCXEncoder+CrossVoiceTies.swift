import SheetMusicCore
import SheetMusicFoundation

/// Both `<location>`s of every tie of one staff whose partner is not the neighbouring chord of its own voice — a tie
/// MuseScore made into another voice (`CrossVoiceTies`), into another staff of the part, or past the chords in between
/// (`DetachedTies`) — filed by where each note sits: measure, then voice, then element, then note.
///
/// The voice walker works a tie's `<location>` out from its own neighbours — the next or previous chord of the same
/// voice — which names the wrong chord for such a tie, so MuseScore found no partner there and dropped it when it
/// opened a file this package wrote. These endpoints are what MuseScore itself writes: the partner's staff as
/// `<staves>`, its voice as `<voices>`, its bar as `<measures>`, its position within that bar relative to this chord's
/// as `<fractions>`.
struct MSCXCrossVoiceTieEndpoints {
    /// The two sides one note can carry.
    struct Ends {
        var forward: TieEndpoint?
        var back: TieEndpoint?
    }

    /// Voice → element → note, for the notes of one measure.
    typealias MeasureEnds = [Int: [Int: [Int: Ends]]]

    private var byMeasure: [Int: MeasureEnds] = [:]

    /// The endpoints of staff `staff` of a part whose staves hold `part`, with that part's detached ties (`detached`,
    /// from `DetachedTies.links`). A staff written on its own passes just its `measures`.
    init(measures: [Measure], staff: Int = 0, part: [[Measure]]? = nil, detached: [DetachedTies.Link] = []) {
        let part = part ?? [measures]
        for link in CrossVoiceTies.links(in: measures) {
            add(
                from: DetachedTies.End(
                    staff: staff, measure: link.from.measure, voice: link.from.voice, element: link.from.element,
                    note: link.from.note,
                ),
                to: DetachedTies.End(
                    staff: staff, measure: link.to.measure, voice: link.to.voice, element: link.to.element,
                    note: link.to.note,
                ),
                offsets: (link.fromOffset, link.toOffset), staff: staff, part: part,
            )
        }
        for link in detached where link.from.staff == staff || link.to.staff == staff {
            add(from: link.from, to: link.to, offsets: (link.fromOffset, link.toOffset), staff: staff, part: part)
        }
    }

    /// The endpoints of the notes of measure `index`, empty for a measure no such tie touches.
    func forMeasure(_ index: Int) -> MeasureEnds {
        byMeasure[index] ?? [:]
    }

    /// File the side of the tie from `from` to `to` that sits on `staff` — both, for a tie within it.
    private mutating func add(
        from: DetachedTies.End, to: DetachedTies.End, offsets: (from: Fraction, to: Fraction), staff: Int,
        part: [[Measure]],
    ) {
        guard let fromNotes = Self.notes(at: from, in: part), let toNotes = Self.notes(at: to, in: part),
              fromNotes.indices.contains(from.note), toNotes.indices.contains(to.note)
        else { return }
        let notesDelta = MSCXLocationNoteIndex.index(ofPitch: toNotes[to.note].pitch, in: toNotes)
            - MSCXLocationNoteIndex.index(ofPitch: fromNotes[from.note].pitch, in: fromNotes)
        let voicesDelta = to.voice - from.voice
        let stavesDelta = to.staff - from.staff
        if from.staff == staff {
            set(\.forward, at: from.inStaff, to: TieEndpoint(
                Self.location(from: (from.measure, offsets.from), to: (to.measure, offsets.to)),
                notesDelta: notesDelta, voicesDelta: voicesDelta, stavesDelta: stavesDelta,
            ))
        }
        if to.staff == staff {
            set(\.back, at: to.inStaff, to: TieEndpoint(
                Self.location(from: (to.measure, offsets.to), to: (from.measure, offsets.from)),
                notesDelta: -notesDelta, voicesDelta: -voicesDelta, stavesDelta: -stavesDelta,
            ))
        }
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

    private static func notes(at end: DetachedTies.End, in part: [[Measure]]) -> ChordNotes? {
        guard part.indices.contains(end.staff) else { return nil }
        let measures = part[end.staff]
        guard measures.indices.contains(end.measure),
              measures[end.measure].voices.indices.contains(end.voice),
              measures[end.measure].voices[end.voice].elements.indices.contains(end.element),
              case let .chord(chord) = measures[end.measure].voices[end.voice].elements[end.element]
        else { return nil }
        return chord.notes
    }
}
