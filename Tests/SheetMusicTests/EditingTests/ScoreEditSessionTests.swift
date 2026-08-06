@testable import SheetMusicCore
import Testing

@Suite("ScoreEditSession")
struct ScoreEditSessionTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let restAt1 = RestID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
    private static let slotAt1 = VoiceElementID(restAt1)

    @Test("inputNote writes a chord into the slot")
    func inputNoteWrites() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.apply(.inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: nil)))
        guard case .chord = session.score[Self.slotAt1] else {
            Issue.record("expected a chord in the slot")
            return
        }
        #expect(session.lastAffectedLocation == Self.slotAt1)
    }

    @Test("inputNote with a duration retimes the slot in the same undo step")
    func inputNoteWithDurationIsOneStep() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.apply(.inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: .half)))
        guard case let .chord(chord) = session.score[Self.slotAt1] else {
            Issue.record("expected a chord in the slot")
            return
        }
        #expect(chord.duration == .half)
        #expect(session.undo())
        #expect(session.canUndo == false) // one step, not two
    }

    @Test("a refused intent leaves the score untouched and reports false")
    func refusedIntentIsANoOp() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let before = session.score.stableFingerprint
        let outOfRange = VoiceElementID(staff: Self.staff, measureIndex: 99, voiceIndex: 0, elementIndex: 0)
        #expect(session.apply(.delete(at: outOfRange)) == false)
        #expect(session.score.stableFingerprint == before)
        #expect(session.canUndo == false)
    }

    @Test("composite applies as one undo step")
    func compositeIsOneStep() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let before = session.score.stableFingerprint
        #expect(session.apply(.composite([
            .inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: nil),
            .setChordDuration(at: Self.slotAt1, duration: .half),
        ])))
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }

    @Test("undo then redo returns to the edited fingerprint")
    func undoRedoRoundTrips() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.apply(.inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: nil)))
        let edited = session.score.stableFingerprint
        #expect(session.undo())
        #expect(session.redo())
        #expect(session.score.stableFingerprint == edited)
    }

    @Test("undo on an empty stack reports false rather than throwing")
    func undoOnEmptyStack() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.undo() == false)
        #expect(session.redo() == false)
    }

    @Test("inputNote inside a tuplet ignores the requested duration but still writes the note")
    func inputNoteInsideTupletIgnoresDuration() throws {
        // Build a triplet across elements 2..4 (three quarter-rests worth of ticks split into thirds), then
        // ask for a note at the tuplet's first member with a duration that the engine would otherwise honor
        // outside a tuplet. The refused length change must not take the note write down with it.
        var score = EditingFixtures.fourQuarterRests()
        let tupletTarget = VoiceElementID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        _ = try CreateTuplet(at: tupletTarget, actualNotes: 3, normalNotes: 2).apply(to: &score)
        let memberDuration = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))

        let session = ScoreEditSession(score: score)
        let restInTuplet = RestID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        let slotInTuplet = VoiceElementID(restInTuplet)
        #expect(session.apply(.inputNote(at: restInTuplet, pitch: 60, tpc: 14, duration: .half)))
        guard case let .chord(chord) = session.score[slotInTuplet] else {
            Issue.record("expected a chord in the slot")
            return
        }
        #expect(chord.duration == memberDuration) // the requested .half was refused and dropped, not honored
        #expect(!chord.notes.isEmpty)
        #expect(session.undo())
        #expect(session.canUndo == false) // one step, even though the plan considered two commands
    }
}
