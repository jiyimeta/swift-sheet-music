@testable import SheetMusicCore
import Testing

/// `SetGraceNotes` — replace both grace lists of a chord (spec row 51).
@Suite("SetGraceNotes")
struct SetGraceNotesTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static let acciaccatura = GraceChord(
        graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 59, tpc: 13)],
    )
    private static let appoggiatura = GraceChord(
        graceType: .appoggiatura, duration: .sixteenth, notes: [Note(pitch: 61, tpc: 21)],
    )
    private static let afterGrace = GraceChord(
        graceType: .grace8after, duration: .eighth, notes: [Note(pitch: 65, tpc: 13)],
    )

    private static func chord(_ score: Score, _ id: VoiceElementID) -> Chord? {
        if case let .chord(chord)? = score[id] { chord } else { nil }
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    @Test("both lists are written, in the order given")
    func writes() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetGraceNotes(
            at: Self.slot(0, 1), before: [Self.acciaccatura, Self.appoggiatura], after: [Self.afterGrace],
        ).apply(to: &score)
        let chord = try #require(Self.chord(score, Self.slot(0, 1)))
        #expect(chord.graceNotesBefore == [Self.acciaccatura, Self.appoggiatura])
        #expect(chord.graceNotesAfter == [Self.afterGrace])
    }

    @Test("undo restores the score exactly, and the command is its own inverse")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try SetGraceNotes(at: Self.slot(0, 1), before: [Self.acciaccatura], after: [])
            .apply(to: &score)
        #expect(inverse is SetGraceNotes)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("two empty lists clear both")
    func clears() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.slot(0, 1)
        _ = try SetGraceNotes(at: target, before: [Self.acciaccatura], after: [Self.afterGrace]).apply(to: &score)
        _ = try SetGraceNotes(at: target, before: [], after: []).apply(to: &score)
        let chord = try #require(Self.chord(score, target))
        #expect(chord.graceNotesBefore.isEmpty)
        #expect(chord.graceNotesAfter.isEmpty)
    }

    @Test("replacing one list replaces the other too — the lists move as a pair")
    func replacesBothTogether() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.slot(0, 1)
        _ = try SetGraceNotes(at: target, before: [Self.acciaccatura], after: [Self.afterGrace]).apply(to: &score)
        _ = try SetGraceNotes(at: target, before: [Self.appoggiatura], after: []).apply(to: &score)
        let chord = try #require(Self.chord(score, target))
        #expect(chord.graceNotesBefore == [Self.appoggiatura])
        #expect(chord.graceNotesAfter.isEmpty)
    }

    @Test("nothing else of the chord moves, and the siblings are untouched")
    func siblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        _ = try SetGraceNotes(at: Self.slot(0, 1), before: [Self.acciaccatura], after: []).apply(to: &score)
        let chord = try #require(Self.chord(score, Self.slot(0, 1)))
        #expect(chord.notes == [Note(pitch: 60, tpc: 14)])
        #expect(chord.duration == .quarter)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
    }

    @Test("a rest, a non-chord element and a missing element are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let onRest = #expect(throws: SheetMusicError.self) {
            _ = try SetGraceNotes(at: Self.slot(0, 3), before: [Self.acciaccatura], after: []).apply(to: &score)
        }
        #expect(Self.reason(of: onRest) == .wrongElementKind(at: Self.slot(0, 3), expected: .chord))
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetGraceNotes(at: Self.slot(0, 9), before: [], after: []).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(0, 9)))
        #expect(score == before)
    }
}
