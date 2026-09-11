@testable import SheetMusicCore
import Testing

@Suite("Grace identity transport")
struct GraceTransportIdentityTests {
    private typealias V = VoiceIdentityFixtures
    private typealias G = GraceTransportFixtures

    /// Renamed from `freshSlotKeepsAssignedGraceIdentity` (SP0 P4 Task 0): a fresh `ReplaceVoiceElement`
    /// handed a chord that already carries assigned grace identity — exactly the same chord read back
    /// from its own slot, the shape a caller replacing one chord with a copy of another produces — used
    /// to keep that identity under the new slot. That was the bug this task closes: `.fresh` now means
    /// "a different chord with different notes" by default, so it clears and reassigns every nested
    /// identifier. `Chord.assignMissingNestedIDs` fills them in a fixed order — the chord's own note,
    /// then the before-grace's slot id, then the after-grace's slot id, then the before-grace's own
    /// note, then the after-grace's own note — so after the slot's own mint (#1) the before/after grace
    /// ids land at #3 and #4, for 6 mints in total.
    @Test func freshSlotClearsAssignedGraceIdentity() throws {
        let editor = ScoreEditor(score: V.score(elements: [G.decorated(.whole)]))
        let before = editor.score
        let initial = editor.idAllocator
        let original = try G.chord(before, 0)
        try editor.apply(ReplaceVoiceElement(at: V.location(0), with: .chord(original), identity: .fresh))
        let result = try G.chord(editor.score, 0)
        #expect(V.ids(V.elements(editor.score)) == [V.minted(initial, 1)])
        G.expectGrace(
            result,
            before: [V.minted(initial, 3)],
            after: [V.minted(initial, 4)],
        )
        #expect(result.graceNotesBefore.eid(at: 0) != original.graceNotesBefore.eid(at: 0))
        #expect(result.graceNotesAfter.eid(at: 0) != original.graceNotesAfter.eid(at: 0))
        #expect(result.notes.eid(at: 0) != original.notes.eid(at: 0))
        // Values only: `Chord`'s `==` never looks at identifiers.
        #expect(result == original)
        #expect(editor.idAllocator == V.advanced(initial, by: 6))
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
        #expect(head.notes.eid(at: 0) == original.notes.eid(at: 0))
        #expect(tail.notes.eid(at: 0) != original.notes.eid(at: 0))
        #expect(V.ids(V.elements(session.score)) == firstIDs)
        // As in the plain cross-bar case: the head keeps its own note identifier now (`CrossBarInputPlanner
        // .piece` no longer re-mints it), so the fresh tail's slot mints first, then its own note — the
        // graces themselves are reused, not reminted, and are not part of either mint.
        #expect(V.ids(V.elements(session.score, measure: 1)) == [
            V.minted(initial, 1), secondIDs[1], secondIDs[2],
        ])
        #expect(session.idAllocator == V.advanced(initial, by: 2))
        let applied = session.score
        for _ in 0 ..< 2 {
            #expect(session.undo())
            V.expectSameScore(session.score, before)
            #expect(session.redo())
            V.expectSameScore(session.score, applied)
            #expect(session.idAllocator == V.advanced(initial, by: 2))
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
        // The head keeps its own note identifier now (`RebarPlanner.pieces`'s `onsetOwnership: .headIsOnset`
        // carries it onto `makeChordChain`'s first piece instead of losing it), so the fresh tail's slot
        // mints first, then its own note, and only then the new measure's system column — the graces
        // themselves are reused, not reminted, and are not part of either mint.
        #expect(V.voiceIDs(editor.score) == [[old[0], old[1]], [V.minted(initial, 1)]])
        #expect(editor.score.systemMeasures.eid(at: 0) == column)
        #expect(editor.score.systemMeasures.eid(at: 1) == V.minted(initial, 3))
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
        #expect(head.notes.eid(at: 0) == original.notes.eid(at: 0))
        #expect(tail.notes.eid(at: 0) != original.notes.eid(at: 0))
        #expect(editor.idAllocator == V.advanced(initial, by: 3))
        try G.expectCycle(editor, before: before)
    }
}
