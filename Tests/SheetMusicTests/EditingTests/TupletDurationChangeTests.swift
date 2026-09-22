import Foundation
@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

/// A length key on a tuplet member — MuseScore's `changeCRlen` with its `tuplet` argument: the requested length is
/// the WRITTEN one, the tuplet's ratio scales it, and the tuplet's own time never changes.
@Suite("Tuplet duration change")
struct TupletDurationChangeTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    private static func chord(_ duration: NoteDuration, _ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    private static let tripletEighth = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))
    private static let tripletSixteenth = NoteDuration.fraction(Fraction(numerator: 1, denominator: 24))
    private static let tripletQuarter = NoteDuration.fraction(Fraction(numerator: 1, denominator: 6))

    /// One 4/4 bar: a quarter G, then `members` under a 3:2 bracket over beat two, then a half rest.
    private static func score(members: [VoiceElement]) -> Score {
        var elements: [VoiceElement] = [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
        elements.append(chord(.quarter, 67, 15))
        elements += members
        elements.append(.rest(duration: .half))
        let voice = Voice(
            elements: elements,
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 1 + members.count)],
        )
        let staffValue = Staff(measures: [Measure(voices: [voice])])
        return Score(division: 480, parts: [Part(id: "P", instrument: Instrument(id: "piano"), staves: [staffValue])])
    }

    /// C D E triplet eighths — a quarter's worth.
    private static func triplet() -> Score {
        score(members: [chord(tripletEighth, 60, 14), chord(tripletEighth, 62, 16), chord(tripletEighth, 64, 18)])
    }

    private static func voice(_ session: ScoreEditSession) -> Voice {
        session.score.parts[0].staves[0].measures[0].voices[0]
    }

    /// The durations and pitches (nil for a rest) the bracket covers, and whether the bar still adds up.
    private static func bracket(_ session: ScoreEditSession) -> [(NoteDuration, Int?)] {
        let voice = voice(session)
        guard let span = voice.tupletSpans.first else { return [] }
        return (span.startIndex ... span.endIndex).compactMap { index in
            guard case let .chord(chord) = voice.elements[index] else { return nil }
            return (chord.duration, chord.notes.first?.pitch)
        }
    }

    private static func barTicks(_ session: ScoreEditSession) -> Int {
        voice(session).elements.reduce(0) { sum, element in
            guard case let .chord(chord) = element else { return sum }
            return sum + chord.duration.ticks(division: 480)
        }
    }

    @Test("a quarter on the first triplet eighth takes the second's time: the beat divides 2:1")
    func lengthenWithinTheBracket() {
        let session = ScoreEditSession(score: Self.triplet())

        #expect(session.apply(.setChordDuration(at: Self.slot(2), duration: .quarter)))

        let members = Self.bracket(session)
        #expect(members.map(\.0) == [Self.tripletQuarter, Self.tripletEighth])
        #expect(members.map(\.1) == [60, 64])
        #expect(Self.voice(session).tupletSpans.first?.normalNotes == 2)
        #expect(Self.voice(session).tupletSpans.first?.actualNotes == 3)
        #expect(Self.barTicks(session) == 1920)
        // Written back as a quarter under the bracket — what the renderers and the encoder read.
        #expect(DurationInterpretation.split(Self.tripletQuarter).base == .quarter)
    }

    @Test("a sixteenth on the first triplet eighth leaves a triplet-sixteenth rest inside the bracket")
    func shortenWithinTheBracket() {
        let session = ScoreEditSession(score: Self.triplet())

        #expect(session.apply(.setChordDuration(at: Self.slot(2), duration: .sixteenth)))

        let members = Self.bracket(session)
        #expect(members.map(\.0) == [
            Self.tripletSixteenth, Self.tripletSixteenth, Self.tripletEighth, Self.tripletEighth,
        ])
        #expect(members.map(\.1) == [60, nil, 62, 64])
        #expect(Self.barTicks(session) == 1920)
    }

    @Test("shortening the last member moves the bracket's end onto the rest that fills it")
    func shortenTheLastMember() {
        let session = ScoreEditSession(score: Self.triplet())

        #expect(session.apply(.setChordDuration(at: Self.slot(4), duration: .sixteenth)))

        let members = Self.bracket(session)
        #expect(members.map(\.1) == [60, 62, 64, nil])
        #expect(members.last?.0 == Self.tripletSixteenth)
        #expect(Self.barTicks(session) == 1920)
    }

    @Test("the length it already has changes nothing")
    func sameWrittenLength() {
        let session = ScoreEditSession(score: Self.triplet())
        let before = Self.bracket(session).map(\.0)

        _ = session.apply(.setChordDuration(at: Self.slot(2), duration: .eighth))

        #expect(Self.bracket(session).map(\.0) == before)
    }

    @Test(
        "more time than the bracket has left is refused, and the score is untouched",
        arguments: [(4, NoteDuration.quarter), (2, NoteDuration.half)],
    )
    func refusedPastTheBracket(element: Int, duration: NoteDuration) {
        let session = ScoreEditSession(score: Self.triplet())
        let before = session.score

        #expect(!session.apply(.setChordDuration(at: Self.slot(element), duration: duration)))

        #expect(session.score == before)
        guard case .insufficientRoom = session.lastRefusal?.reason else {
            Issue.record("expected insufficientRoom, got \(String(describing: session.lastRefusal?.reason))")
            return
        }
    }

    /// C D (triplet sixteenths) E F (triplet eighths): an eighth on D needs half of E, and E's other half stays E.
    @Test("a member consumed in part keeps its pitch for what is left of it")
    func partialConsumption() {
        let session = ScoreEditSession(score: Self.score(members: [
            Self.chord(Self.tripletSixteenth, 60, 14), Self.chord(Self.tripletSixteenth, 62, 16),
            Self.chord(Self.tripletEighth, 64, 18), Self.chord(Self.tripletEighth, 65, 13),
        ]))

        #expect(session.apply(.setChordDuration(at: Self.slot(3), duration: .eighth)))

        let members = Self.bracket(session)
        #expect(members.map(\.0) == [
            Self.tripletSixteenth, Self.tripletEighth, Self.tripletSixteenth, Self.tripletEighth,
        ])
        #expect(members.map(\.1) == [60, 62, 64, 65])
        #expect(Self.barTicks(session) == 1920)
    }

    @Test("a rest inside the bracket takes a written length the same way")
    func restInsideTheBracket() {
        let session = ScoreEditSession(score: Self.score(members: [
            .rest(duration: Self.tripletEighth), Self.chord(Self.tripletEighth, 62, 16),
            Self.chord(Self.tripletEighth, 64, 18),
        ]))

        #expect(session.apply(.setRestDuration(at: Self.slot(2), duration: .quarter)))

        #expect(Self.bracket(session).map(\.0) == [Self.tripletQuarter, Self.tripletEighth])
        #expect(Self.bracket(session).map(\.1) == [nil, 64])
    }

    /// What MuseScore reads back: the members written as a quarter and an eighth under the same 3:2 bracket.
    @Test("the result survives an MSCX round trip")
    func mscxRoundTrip() throws {
        let session = ScoreEditSession(score: Self.triplet())
        #expect(session.apply(.setChordDuration(at: Self.slot(2), duration: .quarter)))

        let xml = try MSCXEncoder.encode(session.score)
        let read = try MSCXParser.parse(xml)
        let voice = read.parts[0].staves[0].measures[0].voices[0]

        #expect(voice.tupletSpans == [TupletSpan(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 3)])
        let durations = { (voice: Voice) in
            voice.elements.values.compactMap { element -> NoteDuration? in
                guard case let .chord(chord) = element else { return nil }
                return chord.duration
            }
        }
        #expect(durations(voice) == durations(Self.voice(session)))
        #expect(String(bytes: xml, encoding: .utf8)?.contains("<durationType>quarter</durationType>") == true)
    }

    @Test("one undo restores the bracket exactly")
    func undo() {
        let session = ScoreEditSession(score: Self.triplet())
        let before = session.score.stableFingerprint

        #expect(session.apply(.setChordDuration(at: Self.slot(2), duration: .quarter)))
        #expect(session.undo())

        #expect(session.score.stableFingerprint == before)
    }
}
