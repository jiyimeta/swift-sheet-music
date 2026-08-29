@testable import SheetMusicCore
import Testing

@Suite("SetNoteHead")
struct SetNoteHeadTests {
    @Test("the head is written onto the note")
    func writesHead() throws {
        var score = EditingFixtures.chordAtIndex1()

        _ = try SetNoteHead(at: EditingFixtures.noteID(element: 1), headType: "cross").apply(to: &score)

        guard case let .chord(chord) = score[VoiceElementID(EditingFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes[0].headType == "cross")
    }

    @Test("undo restores the head the note had, including none")
    func inverseRestores() throws {
        var score = EditingFixtures.chordAtIndex1()
        let before = score
        let inverse = try SetNoteHead(
            at: EditingFixtures.noteID(element: 1), headType: "cross",
        ).apply(to: &score)

        _ = try inverse.apply(to: &score)

        #expect(score == before)
    }

    @Test("nil clears an existing head")
    func clearsHead() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try SetNoteHead(at: EditingFixtures.noteID(element: 1), headType: "cross").apply(to: &score)

        _ = try SetNoteHead(at: EditingFixtures.noteID(element: 1), headType: nil).apply(to: &score)

        guard case let .chord(chord) = score[VoiceElementID(EditingFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes[0].headType == nil)
    }

    @Test("only the addressed note in the chord changes")
    func leavesSiblingsAlone() throws {
        var score = EditingFixtures.twoNoteChordAtIndex1()

        _ = try SetNoteHead(
            at: EditingFixtures.noteID(element: 1, noteIndex: 1), headType: "cross",
        ).apply(to: &score)

        guard case let .chord(chord) = score[VoiceElementID(EditingFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes[0].headType == nil)
        #expect(chord.notes[1].headType == "cross")
    }

    @Test("a note that is not there is refused")
    func refusesMissingNote() {
        var score = EditingFixtures.fourQuarterRests()
        #expect(throws: SheetMusicError.self) {
            _ = try SetNoteHead(at: EditingFixtures.noteID(element: 1), headType: "cross").apply(to: &score)
        }
    }
}
