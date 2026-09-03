@testable import SheetMusicCore
import Testing

@Suite("SetNoteVisible")
struct SetNoteVisibleTests {
    @Test("the flag is written onto the note")
    func writesFlag() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try SetNoteVisible(at: EditingFixtures.noteID(element: 1), visible: false).apply(to: &score)
        #expect(score[EditingFixtures.noteID(element: 1)]?.visible == false)
        #expect(SetNoteVisible.current(at: EditingFixtures.noteID(element: 1), in: score) == false)
    }

    @Test("undo restores the flag the note had")
    func inverseRestores() throws {
        var score = EditingFixtures.chordAtIndex1()
        let before = score
        let inverse = try SetNoteVisible(at: EditingFixtures.noteID(element: 1), visible: false).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("true shows a hidden note again, and the chord's own flags never move")
    func showsAndLeavesChordFlags() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try SetNoteVisible(at: EditingFixtures.noteID(element: 1), visible: false).apply(to: &score)
        guard case let .chord(hidden)? = score[VoiceElementID(EditingFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord")
            return
        }
        #expect(hidden.visible && hidden.stemVisible && hidden.beamVisible) // no cascade — see the doc comment
        _ = try SetNoteVisible(at: EditingFixtures.noteID(element: 1), visible: true).apply(to: &score)
        #expect(score == EditingFixtures.chordAtIndex1())
    }

    @Test("only the addressed note in the chord changes")
    func leavesSiblingsAlone() throws {
        var score = EditingFixtures.twoNoteChordAtIndex1()
        _ = try SetNoteVisible(at: EditingFixtures.noteID(element: 1, noteIndex: 1), visible: false).apply(to: &score)
        #expect(score[EditingFixtures.noteID(element: 1, noteIndex: 0)]?.visible == true)
        #expect(score[EditingFixtures.noteID(element: 1, noteIndex: 1)]?.visible == false)
    }

    @Test("a note that is not there is refused")
    func refusesMissingNote() {
        var score = EditingFixtures.fourQuarterRests()
        let before = score
        let error = #expect(throws: SheetMusicError.self) {
            _ = try SetNoteVisible(at: EditingFixtures.noteID(element: 1), visible: false).apply(to: &score)
        }
        guard case let .invalidEdit(refusal)? = error else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal.reason == .noteNotFound(EditingFixtures.noteID(element: 1)))
        #expect(score == before)
    }
}
