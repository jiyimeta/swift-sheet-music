@testable import SheetMusicCore
import Testing

@Suite("DuplicateRange intent")
struct DuplicateRangeIntentTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    @Test("the intent applies as one undo step")
    func appliesAsOneStep() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let before = session.score
        #expect(session.apply(.duplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(0, 2),
        ))))
        #expect(session.score != before)
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before.stableFingerprint)
    }

    @Test("an unresolvable range refuses with targetNotFound")
    func refuses() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(!session.apply(.duplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(9, 0),
        ))))
        guard case .targetNotFound = session.lastRefusal?.reason else {
            Issue.record("expected targetNotFound, got \(String(describing: session.lastRefusal?.reason))")
            return
        }
    }

    /// A dotted half (three quarter beats) turned into a triplet, followed by a plain quarter. The triplet's
    /// members land at indices 0-2; the quarter is index 3.
    private static func tripletThenQuarter() throws -> Score {
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .chord(Chord(
                    duration: .fraction(Fraction(numerator: 3, denominator: 4)), notes: [Note(pitch: 60, tpc: 14)],
                )),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            ])]),
        ])
        var score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
        _ = try CreateTuplet(at: Self.slot(0, 0), actualNotes: 3, normalNotes: 2).apply(to: &score)
        return score
    }

    @Test("a range that cuts a tuplet refuses with insideTuplet, and leaves the score untouched")
    func refusesPartialTuplet() throws {
        let score = try Self.tripletThenQuarter()
        let session = ScoreEditSession(score: score)
        #expect(!session.apply(.duplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(0, 3),
        ))))
        guard case .insideTuplet = session.lastRefusal?.reason else {
            Issue.record("expected insideTuplet, got \(String(describing: session.lastRefusal?.reason))")
            return
        }
        #expect(session.score.stableFingerprint == score.stableFingerprint)
    }

    @Test("element identifiers survive apply, undo and redo")
    func identityRoundTrips() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let before = session.score.stableFingerprint
        #expect(session.apply(.duplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(0, 2),
        ))))
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
        #expect(session.redo())
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }

    /// A bar's accidentals are in force only until its barline, so a copy that moves a sharp into a new bar
    /// changes what every later note in that bar reads as. The session bundles the repair into the same step.
    private static func sharpBeforeANaturalInTheNextBar() -> Score {
        var score = EditingFixtures.parityFixture()
        // Beat 4 of bar 0 becomes F♯4, carrying the ♯ glyph its own bar already owes it — without that the
        // pass below would report bar 0's missing glyph and say nothing about the copy. Beat 2 of bar 1 is an
        // F natural that needs no glyph while it stands alone in its bar.
        score[Self.slot(0, 4)] = .chord(Chord(
            duration: .quarter, notes: [Note(pitch: 66, tpc: 20, accidental: .sharp)],
        ))
        score[Self.slot(1, 1)] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)]))
        return score
    }

    @Test("a copied bar leaves the following notes' accidentals correctly renotated")
    func renotatesAfterTheCopy() throws {
        // Copying beat 4 puts the F♯ on beat 1 of bar 1, in front of that bar's F natural.
        let range = VoiceElementRange(start: Self.slot(0, 4), end: Self.slot(0, 4))
        // The raw command writes the copy and nothing else, so the F natural is left reading sharp — which is
        // what makes the session's result below evidence of a repair rather than of nothing to repair.
        var raw = Self.sharpBeforeANaturalInTheNextBar()
        _ = try DuplicateRange(over: range).apply(to: &raw)
        #expect(MeasureAccidentals.renotationCommands(in: raw, measureRange: 1 ..< 2).count == 1)

        let session = ScoreEditSession(score: Self.sharpBeforeANaturalInTheNextBar())
        #expect(session.apply(.duplicateRange(over: range)))
        #expect(MeasureAccidentals.renotationCommands(in: session.score, measureRange: 0 ..< 2).isEmpty)
    }

    @Test("the command and the intent produce the same score")
    func agreesWithCommand() throws {
        var direct = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)))
            .apply(to: &direct)
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(session.apply(.duplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(0, 2),
        ))))
        #expect(direct.stableFingerprint == session.score.stableFingerprint)
    }
}
