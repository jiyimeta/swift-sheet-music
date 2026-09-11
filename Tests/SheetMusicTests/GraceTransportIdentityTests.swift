@testable import SheetMusicCore
import Testing

@Suite("Grace identity transport")
struct GraceTransportIdentityTests {
    private typealias V = VoiceIdentityFixtures
    private typealias G = GraceTransportFixtures

    @Test func freshSlotKeepsAssignedGraceIdentity() throws {
        let editor = ScoreEditor(score: V.score(elements: [G.decorated(.whole)]))
        let before = editor.score
        let initial = editor.idAllocator
        let original = try G.chord(before, 0)
        try editor.apply(ReplaceVoiceElement(at: V.location(0), with: .chord(original), identity: .fresh))
        let result = try G.chord(editor.score, 0)
        #expect(V.ids(V.elements(editor.score)) == [V.minted(initial, 1)])
        G.expectGrace(
            result,
            before: [original.graceNotesBefore.eid(at: 0)],
            after: [original.graceNotesAfter.eid(at: 0)],
        )
        #expect(result == original)
        #expect(editor.idAllocator == V.advanced(initial, by: 1))
        try G.expectCycle(editor, before: before)
    }

    @Test func wholeChordMovesToExistingVoiceWithBothGraceLists() throws {
        let editor = ScoreEditor(score: V.score([[
            Voice(elements: [G.decorated(.whole)]), Voice(elements: [.rest(duration: .measure)]),
        ]]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = V.elements(before).eid(at: 0)
        let original = try G.chord(before, 0)
        try editor.apply(MoveToVoice(
            at: V.location(0), to: VoiceRef(staff: V.staff, measureIndex: 0, voiceIndex: 1),
        ))
        #expect(V.ids(V.elements(editor.score)) == [V.minted(initial, 1)])
        #expect(V.ids(V.elements(editor.score, voice: 1)) == [old])
        #expect(V.elements(editor.score)[0].isRest)
        let moved = try G.chord(editor.score, 0, voice: 1)
        G.expectGrace(
            moved,
            before: [original.graceNotesBefore.eid(at: 0)],
            after: [original.graceNotesAfter.eid(at: 0)],
        )
        #expect(moved == original)
        #expect(editor.idAllocator == V.advanced(initial, by: 1))
        try G.expectCycle(editor, before: before)
    }

    @Test func crossBarKeepsBeforeOnHeadAndMovesAfterToFreshTail() throws {
        let session = ScoreEditSession(score: V.score([
            [Voice(elements: [V.time, .rest(duration: .half), .rest(duration: .quarter), G.decorated()])],
            [Voice(elements: [.rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .half)])],
        ]))
        let before = session.score
        let initial = session.idAllocator
        let firstIDs = V.ids(V.elements(before))
        let secondIDs = V.ids(V.elements(before, measure: 1))
        let original = try G.chord(before, 3)
        #expect(session.apply(.setChordDuration(at: V.location(3), duration: .half)))
        let head = try G.chord(session.score, 3)
        let tail = try G.chord(session.score, 0, measure: 1)
        G.expectGrace(head, before: [original.graceNotesBefore.eid(at: 0)], after: [])
        G.expectGrace(tail, before: [], after: [original.graceNotesAfter.eid(at: 0)])
        #expect(head.graceNotesBefore.values == original.graceNotesBefore.values)
        #expect(tail.graceNotesAfter.values == original.graceNotesAfter.values)
        #expect(head.notes[0].tieForward == 1)
        #expect(tail.notes[0].tieBack == 1)
        #expect(V.ids(V.elements(session.score)) == firstIDs)
        // As in the plain cross-bar case: the head's own (now tied) note mints, then the fresh tail's
        // slot, then the tail's own note — the graces themselves are reused, not reminted.
        #expect(V.ids(V.elements(session.score, measure: 1)) == [
            V.minted(initial, 2), secondIDs[1], secondIDs[2],
        ])
        #expect(session.idAllocator == V.advanced(initial, by: 3))
        let applied = session.score
        for _ in 0 ..< 2 {
            #expect(session.undo())
            V.expectSameScore(session.score, before)
            #expect(session.redo())
            V.expectSameScore(session.score, applied)
            #expect(session.idAllocator == V.advanced(initial, by: 3))
        }
    }

    @Test func rebarMovesAssignedAfterGraceToFreshTail() throws {
        let editor = ScoreEditor(score: V.score(elements: [V.time, G.decorated(.whole)]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = V.ids(V.elements(before))
        let column = before.systemMeasures.eid(at: 0)
        let original = try G.chord(before, 1)
        try editor.apply(SetTimeSignature(measureIndex: 0, numerator: 2, denominator: 4))
        // The head's own (now tied) note mints, then the fresh tail's slot, then the tail's own note,
        // and only then the new measure's system column — the graces themselves are reused, not reminted.
        #expect(V.voiceIDs(editor.score) == [[old[0], old[1]], [V.minted(initial, 2)]])
        #expect(editor.score.systemMeasures.eid(at: 0) == column)
        #expect(editor.score.systemMeasures.eid(at: 1) == V.minted(initial, 4))
        let head = try G.chord(editor.score, 1)
        let tail = try G.chord(editor.score, 0, measure: 1)
        G.expectGrace(head, before: [original.graceNotesBefore.eid(at: 0)], after: [])
        G.expectGrace(tail, before: [], after: [original.graceNotesAfter.eid(at: 0)])
        #expect(head.graceNotesBefore.values == original.graceNotesBefore.values)
        #expect(tail.graceNotesAfter.values == original.graceNotesAfter.values)
        #expect(head.duration == .half)
        #expect(tail.duration == .half)
        #expect(head.notes[0].tieForward == 1)
        #expect(tail.notes[0].tieBack == 1)
        #expect(editor.idAllocator == V.advanced(initial, by: 4))
        try G.expectCycle(editor, before: before)
    }
}
