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
}
