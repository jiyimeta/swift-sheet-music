import SheetMusicCore

enum RemovalRoundTripFixtures {
    static let canonical = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    static let fullOwner = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    static let hidden: Set<StaffAddress> = [canonical, StaffAddress(partIndex: 1, staffIndexInPart: 0)]

    static func slot(_ index: Int, staff: StaffAddress = canonical, measure: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: index)
    }

    static func note(_ measure: Int, staff: StaffAddress = canonical) -> NoteID {
        NoteID(
            staff: staff,
            measureIndex: measure,
            voiceIndex: 0,
            elementIndex: measure == 0 ? 0 : 1,
            noteIndexInChord: 0,
        )
    }

    static func score(_ measures: [Measure], filtered: Bool = false) -> Score {
        let owner = Staff(measures: measures)
        let blank = Staff(measures: measures.map { _ in
            Measure(voices: [Voice(elements: [.rest(duration: .whole)])])
        })
        let parts: [Part] = filtered ? [
            Part(id: "hidden", instrument: Instrument(id: "x"), staves: [blank]),
            Part(id: "visible", instrument: Instrument(id: "x"), staves: [blank, owner]),
        ] : [Part(id: "visible", instrument: Instrument(id: "x"), staves: [owner])]
        return ScoreEditor(score: Score(division: 480, parts: IdentifiedArray(parts))).score
    }

    static func tie(filtered: Bool) -> Score {
        score([
            Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [Note(pitch: 79, tpc: 15, tieForward: 7)])),
            ])], lineBreak: true),
            Measure(voices: [Voice(elements: [
                // Keep the END segment away from the first content column: a one-sp segment at the
                // first note lies entirely inside that note's higher-priority 1.2-sp hit disk.
                .rest(duration: .quarter),
                .chord(Chord(duration: .half.dotted(1), notes: [Note(pitch: 79, tpc: 15, tieBack: 7)])),
            ])], jumps: [Jump(jumpTo: "start", playUntil: "end", text: "D.C.")]),
        ], filtered: filtered)
    }

    static let shortSlur = Spanner(
        kind: .slur, rawType: "short", nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
    )
    static let longSlur = Spanner(
        kind: .slur, rawType: "long", nextFractionsOffset: Fraction(numerator: 3, denominator: 4),
    )

    static func slurs(standalone: Bool) -> Score {
        let notes: ChordNotes = [Note(pitch: 79, tpc: 15)]
        var head = Chord(duration: .quarter, notes: notes)
        head.spanners = standalone ? [] : [shortSlur, longSlur]
        var elements: [VoiceElement] = [.chord(head)]
        if standalone {
            elements.insert(.spanner(longSlur), at: 0)
        }
        elements.append(.chord(Chord(duration: .quarter, notes: notes)))
        if standalone {
            elements.append(.spanner(Spanner(
                kind: .slur, rawType: "later", nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
            )))
        }
        elements.append(.chord(Chord(duration: .quarter, notes: notes)))
        elements.append(.chord(Chord(duration: .quarter, notes: notes)))
        return score([Measure(voices: [Voice(elements: elements)])])
    }

    static func navigation(filtered: Bool) -> Score {
        score([Measure(voices: [Voice(elements: [.rest(duration: .whole)])], markers: [
            Marker(kind: .segno, label: "segno", text: "Segno"),
            Marker(kind: .coda, label: "coda", text: "Coda"),
        ], jumps: [
            Jump(jumpTo: "segno", playUntil: "end", text: "D.S."),
            Jump(jumpTo: "start", playUntil: "end", text: "D.C."),
        ])], filtered: filtered)
    }
}
