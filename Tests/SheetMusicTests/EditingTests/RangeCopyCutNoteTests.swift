@testable import SheetMusicCore
import SheetMusicFoundation
import Testing

/// A copied note that sounds past the range's end is shortened to fit, as MuseScore shortens it
/// (`read460.cpp:602-633`): the chord stays the same chord, so everything on it stays too. Where the shortened length
/// takes several tied notes, the first keeps the marks and the rest keep only a single-chord tremolo
/// (`Score::pasteChordRest`, `paste.cpp:163-206`; `Chord::removeMarkings(true)`, `chord.cpp:2045`).
@Suite("A copied note cut by the range's end")
struct RangeCopyCutNoteTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let bar = 2880

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    private static func plain(_ pitch: Int, _ duration: NoteDuration) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: 15)]))
    }

    /// A chord carrying everything a chord can carry but a two-note tremolo.
    private static func marked(_ duration: NoteDuration) -> Chord {
        var chord = Chord(
            duration: duration,
            notes: [Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18)],
            arpeggio: Arpeggio(subtype: 0),
            lyrics: [Lyric(text: "la")],
            graceNotesBefore: [GraceChord(
                graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 62, tpc: 16)],
            )],
            graceNotesAfter: [GraceChord(
                graceType: .grace16after, duration: .sixteenth, notes: [Note(pitch: 65, tpc: 13)],
            )],
            articulations: [ChordArticulation(kind: .staccato, anchor: .above)],
            ornaments: [ChordOrnament(
                kind: .trill, intervalAbove: .init(step: .second, quality: .major), plays: false,
                accidentalAbove: .sharp, anchor: .bottom,
            )],
            tremolo: Tremolo(subtype: .r16),
            chordLines: [ChordLine(kind: .fall)],
            visible: false, stemVisible: false, stemDirection: .up,
        )
        chord.beamMode = .begin
        return chord
    }

    /// 6/4. Voice 1: a quarter, an eighth, a quarter, an eighth, a half, a quarter, ending at 480, 720, 1200, 1440,
    /// 2400 and 2880. Voice 2 is `second`. The bar after it rests.
    private static func score(second: [VoiceElement]) -> Score {
        Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "piano"),
            staves: [Staff(defaultClefType: "G", measures: [
                Measure(voices: [
                    Voice(elements: [
                        .timeSignature(TimeSignature(numerator: 6, denominator: 4)),
                        plain(79, .quarter), plain(79, .eighth), plain(79, .quarter), plain(79, .eighth),
                        plain(79, .half), plain(79, .quarter),
                    ]),
                    Voice(elements: second),
                ]),
                Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
            ])],
        )])
    }

    /// Repeats voice 1's slots `1 ... last`, `length` ticks, and answers what voice 2 holds where the copy landed.
    private static func copied(_ second: [VoiceElement], through last: Int, length: Int) throws -> [Chord] {
        let session = ScoreEditSession(score: score(second: second))
        let range = VoiceElementRange(start: slot(1), end: slot(last))
        try #require(
            session.apply(.duplicateRange(over: range)), "refused: \(String(describing: session.lastRefusal))",
        )
        var found: [Chord] = []
        for (index, measure) in session.score.parts[0].staves[0].measures.enumerated() {
            guard measure.voices.indices.contains(1) else { continue }
            var tick = index * bar
            for element in measure.voices[1].elements.values {
                if case let .chord(chord) = element, (length ..< 2 * length).contains(tick) { found.append(chord) }
                tick += element.cursorAdvance(division: 480, in: Fraction(numerator: 6, denominator: 4))
            }
        }
        return found
    }

    struct Mark: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let value: @Sendable (Chord) -> String
    }

    /// What goes with the note's onset: the first piece has it, and no other does.
    private static let marks: [Mark] = [
        Mark(testDescription: "articulations") { "\($0.articulations)" },
        Mark(testDescription: "ornaments") { "\($0.ornaments)" },
        Mark(testDescription: "grace notes before") { graces($0.graceNotesBefore) },
        Mark(testDescription: "grace notes after") { graces($0.graceNotesAfter) },
        Mark(testDescription: "chord lines") { "\($0.chordLines)" },
        Mark(testDescription: "arpeggio") { "\(String(describing: $0.arpeggio))" },
        Mark(testDescription: "lyrics") { "\($0.lyrics)" },
    ]

    /// What else the chord says about itself: the first piece's.
    private static let properties: [Mark] = [
        Mark(testDescription: "tremolo") { "\(String(describing: $0.tremolo))" },
        Mark(testDescription: "visibility") { "\($0.visible)" },
        Mark(testDescription: "stem visibility") { "\($0.stemVisible)" },
        Mark(testDescription: "stem direction") { "\(String(describing: $0.stemDirection))" },
        Mark(testDescription: "beam mode") { "\($0.beamMode)" },
    ]

    /// Without the identities the edit gives a copy's notes.
    private static func graces(_ graces: IdentifiedArray<GraceChord>) -> String {
        "\(graces.values.map { ($0.graceType, $0.duration, $0.notes.map(\.pitch)) })"
    }

    private static let whole = NoteDuration.fraction(Fraction(numerator: 3, denominator: 2))

    @Test("shortened to one note, it keeps everything on it", arguments: marks + properties)
    func oneNote(mark: Mark) throws {
        let source = Self.marked(Self.whole)
        let copy = try Self.copied([.chord(source)], through: 4, length: 1440)
        #expect(copy.map { $0.duration.ticks(division: 480) } == [1440])
        #expect(copy.map(mark.value) == [mark.value(source)])
    }

    @Test("shortened to several tied notes, the first has the marks and the rest have none", arguments: marks)
    func tiedNotes(mark: Mark) throws {
        let source = Self.marked(Self.whole)
        let none = mark.value(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let copy = try Self.copied([.chord(source)], through: 3, length: 1200)
        try #require(copy.count > 1)
        #expect(copy.reduce(0) { $0 + $1.duration.ticks(division: 480) } == 1200)
        #expect(copy.map(mark.value) == [mark.value(source)] + copy.dropFirst().map { _ in none })
    }

    @Test("cut by the range's end and by a barline, the first has the marks and the rest have none", arguments: marks)
    func acrossABarline(mark: Mark) throws {
        let source = Self.marked(Self.whole)
        let none = mark.value(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let copy = try Self.copied([.chord(source)], through: 5, length: 2400)
        try #require(copy.count > 1)
        #expect(copy.reduce(0) { $0 + $1.duration.ticks(division: 480) } == 2400)
        #expect(copy.map(mark.value) == [mark.value(source)] + copy.dropFirst().map { _ in none })
    }

    @Test("a tremolo runs through every tied note", arguments: [(3, 1200), (5, 2400)])
    func tremolo(through last: Int, length: Int) throws {
        let copy = try Self.copied([.chord(Self.marked(Self.whole))], through: last, length: length)
        try #require(copy.count > 1)
        #expect(copy.map(\.tremolo) == copy.map { _ in Tremolo(subtype: .r16) })
    }

    @Test("a tie from a copied note into the cut one stays; the one leaving it goes")
    func ties() throws {
        func tied(_ duration: NoteDuration, back: Bool, forward: Bool) -> VoiceElement {
            var note = Note(pitch: 60, tpc: 14)
            if back { note.tieBack = 1 }
            if forward { note.tieForward = 1 }
            return .chord(Chord(duration: duration, notes: [note]))
        }
        let copy = try Self.copied(
            [
                tied(.half, back: false, forward: true),
                tied(.half, back: true, forward: true),
                tied(.half, back: true, forward: false),
            ],
            through: 3, length: 1200,
        )
        #expect(copy.map { $0.duration.ticks(division: 480) } == [960, 240])
        #expect(copy.map { $0.notes[0].tieBack } == [nil, 1])
        #expect(copy.map { $0.notes[0].tieForward } == [1, nil])
    }

    private static func pair(_ duration: NoteDuration) -> [VoiceElement] {
        var first = Chord(
            duration: duration, notes: [Note(pitch: 60, tpc: 14)], tremolo: Tremolo(subtype: .r16, span: .between),
        )
        var second = Chord(duration: duration, notes: [Note(pitch: 64, tpc: 18)])
        first.isWrittenDoubled = true
        second.isWrittenDoubled = true
        return [.chord(first), .chord(second)]
    }

    /// MuseScore takes the tremolo off the note before a shortened one (`read460.cpp:606-625`), so that no pair has
    /// two lengths; a pair cut in its first note it refuses to copy (`checkEndForPartialCopy`, `select.cpp:1434`),
    /// and here the one note that is copied has no partner.
    @Test("a two-note tremolo whose pair is cut goes, and both notes are written as long as they last", arguments: [
        (NoteDuration.quarter, [480, 240]), (.half, [720]),
    ])
    func twoNoteTremolo(duration: NoteDuration, lengths: [Int]) throws {
        let rests: [VoiceElement] = duration == .quarter
            ? [.rest(duration: .half), .rest(duration: .half)] : [.rest(duration: .half)]
        let copy = try Self.copied(Self.pair(duration) + rests, through: 2, length: 720)
        #expect(copy.reduce(0) { $0 + $1.duration.ticks(division: 480) } == lengths.reduce(0, +))
        #expect(copy.allSatisfy { $0.tremolo == nil && !$0.isWrittenDoubled })
    }

    @Test("a two-note tremolo copied whole keeps its pair")
    func wholeTwoNoteTremolo() throws {
        let copy = try Self.copied(
            Self.pair(.quarter) + [.rest(duration: .half), .rest(duration: .half)], through: 4, length: 1440,
        )
        #expect(copy.prefix(2).map(\.tremolo) == [Tremolo(subtype: .r16, span: .between), nil])
        #expect(copy.prefix(2).map(\.isWrittenDoubled) == [true, true])
    }
}
