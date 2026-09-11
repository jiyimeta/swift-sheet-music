import SheetMusicCore
import Testing

@Suite("Note identity assignment")
struct NoteIdentityAssignmentTests {
    private typealias F = GraceIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    private func scoreWithGraces() -> Score {
        F.score(before: [F.grace(), F.grace(61)], after: [F.grace(63)])
    }

    @Test("every note of every chord and grace is identified on adoption")
    func adoptionIdentifiesEveryNote() {
        let editor = ScoreEditor(score: scoreWithGraces())
        #expect(!editor.score.hasUnassignedIDs)
        var seen = Set<EID>()
        var count = 0
        for part in editor.score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for element in voice.elements {
                            guard case let .chord(chord) = element else { continue }
                            for index in chord.notes.indices {
                                #expect(chord.notes.eid(at: index).isValid)
                                #expect(seen.insert(chord.notes.eid(at: index)).inserted)
                                count += 1
                            }
                            for grace in chord.graceNotesBefore.values + chord.graceNotesAfter.values {
                                for index in grace.notes.indices {
                                    #expect(grace.notes.eid(at: index).isValid)
                                    #expect(seen.insert(grace.notes.eid(at: index)).inserted)
                                    count += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(count > 0) // a walk that visited nothing must not read as a pass
    }

    @Test("a command that lands a literal chord identifies its notes")
    func inputNoteIdentifiesTheNoteItLands() throws {
        // InputNote builds Chord(notes: [Note(...)]) from a literal and lands it through
        // ReplaceVoiceElement. Before the rename this left an unassigned slot and tripped
        // ScoreEditor's out-assert.
        let editor = ScoreEditor(score: EditingFixtures.fourQuarterRests())
        let restID = EditingFixtures.restID(element: 1)
        try editor.apply(InputNote(at: restID, pitch: 60, tpc: 14))
        guard case let .chord(chord) = editor.score[VoiceElementID(restID)] else {
            fatalError("a chord landed")
        }
        #expect(chord.notes.count == 1)
        #expect(chord.notes.eid(at: 0).isValid)
    }

    @Test("a chord split into a tied chain keeps the head's note identifiers and mints the rest")
    func chainContinuationsGetNewNoteIdentifiers() {
        // A chord lengthened past its bar's end has to cross the barline as a tied chain
        // (`CrossBarInputPlanner`) — the one command that splits a chord already in the score into
        // multiple pieces. The head is the chord's own onset landing in the first piece, so it keeps the
        // chord's note identifier; the tail is new continuation material and mints its own.
        let session = ScoreEditSession(score: V.score([
            [Voice(elements: [V.time, .rest(duration: .half), .rest(duration: .quarter), V.chord()])],
            [Voice(elements: [.rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .half)])],
        ]))
        guard case let .chord(original) = V.elements(session.score)[3] else {
            Issue.record("fixture is a chord")
            return
        }
        let originalNoteID = original.notes.eid(at: 0)
        #expect(session.apply(.setChordDuration(at: V.location(3), duration: .half)))
        guard case let .chord(head) = V.elements(session.score)[3] else {
            Issue.record("head is a chord")
            return
        }
        guard case let .chord(tail) = V.elements(session.score, measure: 1)[0] else {
            Issue.record("tail is a chord")
            return
        }
        #expect(head.notes.eid(at: 0) == originalNoteID)
        #expect(tail.notes.eid(at: 0) != originalNoteID)
        #expect(tail.notes.eid(at: 0).isValid)
    }

    @Test("adding a note mints one identifier and leaves the others alone")
    func addNoteMintsOneIdentifier() throws {
        let editor = ScoreEditor(score: EditingFixtures.chordAtIndex1())
        let location = VoiceElementID(
            staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )
        guard case let .chord(before) = editor.score[location] else { fatalError("fixture is a chord") }
        let existing = before.notes.eid(at: 0)
        try editor.apply(AddNoteToChord(at: location, pitch: 67, tpc: 15))
        guard case let .chord(after) = editor.score[location] else { fatalError("still a chord") }
        #expect(after.notes.count == before.notes.count + 1)
        #expect(after.notes.eid(at: 0) == existing)
        #expect(after.notes.eid(at: after.notes.count - 1).isValid)
    }

    @Test("undoing a removal restores the removed note's identifier")
    func undoRestoresTheRemovedNoteIdentifier() throws {
        let editor = ScoreEditor(score: EditingFixtures.twoNoteChordAtIndex1())
        let location = EditingFixtures.noteID(element: 1, noteIndex: 1)
        guard case let .chord(before) = editor.score[VoiceElementID(location)]
        else { fatalError("fixture is a chord") }
        let removed = before.notes.eid(at: 1)
        try editor.apply(RemoveNoteFromChord(at: location))
        try editor.undo()
        guard case let .chord(after) = editor.score[VoiceElementID(location)]
        else { fatalError("still a chord") }
        #expect(after.notes.eid(at: 1) == removed)
    }

    @Test("an already assigned note identifier is not re-minted")
    func adoptionKeepsAssignedNoteIdentifiers() {
        var ids = EIDAllocator(actor: 3)
        var score = V.score(elements: [V.chord()])
        score.assignMissingIDs(using: &ids)
        guard case let .chord(before) = score.parts[0].staves[0].measures[0].voices[0].elements[0]
        else { fatalError("fixture is a chord") }
        let kept = before.notes.eid(at: 0)
        let editor = ScoreEditor(score: score)
        guard case let .chord(after) = editor.score.parts[0].staves[0].measures[0].voices[0].elements[0]
        else { fatalError("still a chord") }
        #expect(after.notes.eid(at: 0) == kept)
    }

    @Test("a transposed display copy keeps each note's identifier")
    func displayTransposeKeepsNoteIdentity() {
        let editor = ScoreEditor(score: EditingFixtures.chordAtIndex1())
        let location = VoiceElementID(
            staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )
        guard case let .chord(committed) = editor.score[location] else { fatalError("fixture is a chord") }
        let displayed = editor.score.transposed(bySemitones: 2)
        guard case let .chord(shown) = displayed[location] else { fatalError("still a chord") }
        #expect(shown.notes[0].pitch != committed.notes[0].pitch) // the transform did something
        #expect(shown.notes.eid(at: 0) == committed.notes.eid(at: 0))
    }
}
