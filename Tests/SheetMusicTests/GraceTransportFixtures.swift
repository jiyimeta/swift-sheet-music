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
