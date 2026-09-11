@testable import SheetMusicCore
import Testing

enum GraceTransportFixtures {
    private enum FixtureError: Error { case expectedChord }
    static func decorated(_ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(
            duration: duration, notes: [Note(pitch: 63, tpc: 23)],
            graceNotesBefore: [GraceChord(
                graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 62, tpc: 16)],
            )],
            graceNotesAfter: [GraceChord(
                graceType: .grace16after, duration: .sixteenth, notes: [Note(pitch: 65, tpc: 13)],
            )],
        ))
    }

    static func chord(_ score: Score, _ index: Int, measure: Int = 0, voice: Int = 0) throws -> Chord {
        let element = VoiceIdentityFixtures.elements(score, measure: measure, voice: voice)[index]
        guard case let .chord(chord) = element else {
            Issue.record("Expected a chord")
            throw FixtureError.expectedChord
        }
        return chord
    }

    static func expectGrace(
        _ chord: Chord, before: [EID], after: [EID], sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        let beforeIDs = chord.graceNotesBefore.indices.map { chord.graceNotesBefore.eid(at: $0) }
        let afterIDs = chord.graceNotesAfter.indices.map { chord.graceNotesAfter.eid(at: $0) }
        #expect(beforeIDs == before, sourceLocation: sourceLocation)
        #expect(afterIDs == after, sourceLocation: sourceLocation)
    }

    /// Every note identifier reachable from `score` — each chord's own notes plus each grace chord's own
    /// notes, across every part / staff / measure / voice. Delegates the per-chord collection to
    /// `EditingIdentityInvariants.noteIdentifiers(of:)`, the same helper the debug gate's
    /// `identifiers(in:)` traversal now uses, so this fixture and the production gate cannot drift on
    /// what counts as a note. (Before EID-P3-Task-3, `identifiers(in:)` did not walk into `chord.notes`
    /// at all, and this fixture duplicated the collection logic standalone.)
    static func allNoteIDs(_ score: Score) -> [EID] {
        var result: [EID] = []
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for element in voice.elements {
                            guard case let .chord(chord) = element else { continue }
                            result.append(contentsOf: EditingIdentityInvariants.noteIdentifiers(of: chord))
                        }
                    }
                }
            }
        }
        return result
    }

    static func expectCycle(
        _ editor: ScoreEditor, before: Score, sourceLocation: SourceLocation = #_sourceLocation,
    ) throws {
        let applied = editor.score
        let allocator = editor.idAllocator
        for _ in 0 ..< 2 {
            try editor.undo()
            VoiceIdentityFixtures.expectSameScore(editor.score, before, sourceLocation: sourceLocation)
            try editor.redo()
            VoiceIdentityFixtures.expectSameScore(editor.score, applied, sourceLocation: sourceLocation)
            #expect(editor.idAllocator == allocator, sourceLocation: sourceLocation)
        }
    }
}
