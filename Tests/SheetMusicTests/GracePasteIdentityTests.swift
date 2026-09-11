@testable import SheetMusicCore
import Testing

@Suite("Grace paste identity")
struct GracePasteIdentityTests {
    private typealias V = VoiceIdentityFixtures
    private typealias G = GraceTransportFixtures

    @Test func sameDurationPasteRemintsBothGraceListsAndLeavesSource() throws {
        let editor = ScoreEditor(score: V.score(elements: [
            G.decorated(), .rest(duration: .quarter), .rest(duration: .half),
        ]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = V.ids(V.elements(before))
        let source = try G.chord(before, 0)
        try editor.apply(PasteVoiceElement(at: V.location(1), element: .chord(source)))
        #expect(V.ids(V.elements(editor.score)) == [old[0], V.minted(initial, 1), old[2]])
        let original = try G.chord(editor.score, 0)
        let copied = try G.chord(editor.score, 1)
        G.expectGrace(
            original,
            before: [source.graceNotesBefore.eid(at: 0)],
            after: [source.graceNotesAfter.eid(at: 0)],
        )
        // Mint order after the pasted slot's own EID: the chord's own note, then both grace slot lists,
        // then each grace's own note — `clearNestedIDsForCopy` now wipes the chord's own note too, so it
        // mints before the grace lists rather than leaving the source's note identifier in place.
        #expect(copied.notes.eid(at: 0) == V.minted(initial, 2))
        #expect(copied.notes.eid(at: 0) != source.notes.eid(at: 0))
        G.expectGrace(copied, before: [V.minted(initial, 3)], after: [V.minted(initial, 4)])
        #expect(copied == source)
        #expect(editor.idAllocator == V.advanced(initial, by: 6))
        try G.expectCycle(editor, before: before)
    }

    @Test func shorterPasteMintsChordThenGraceThenPaddingRest() throws {
        let editor = ScoreEditor(score: V.score(elements: [
            G.decorated(), .rest(duration: .half), .rest(duration: .quarter),
        ]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = V.ids(V.elements(before))
        let source = try G.chord(before, 0)
        try editor.apply(PasteVoiceElement(at: V.location(1), element: .chord(source)))
        // The padding rest is the last mint: pastedEID, then the widened nested walk (chord's own note,
        // both grace slot lists, each grace's own note — 5 mints), then the rest that pads the leftover.
        #expect(V.ids(V.elements(editor.score)) == [old[0], V.minted(initial, 1), V.minted(initial, 7), old[2]])
        let copied = try G.chord(editor.score, 1)
        let original = try G.chord(editor.score, 0)
        G.expectGrace(
            original,
            before: [source.graceNotesBefore.eid(at: 0)],
            after: [source.graceNotesAfter.eid(at: 0)],
        )
        #expect(copied.notes.eid(at: 0) == V.minted(initial, 2))
        #expect(copied.notes.eid(at: 0) != source.notes.eid(at: 0))
        G.expectGrace(copied, before: [V.minted(initial, 3)], after: [V.minted(initial, 4)])
        #expect(V.elements(editor.score).values == [
            .chord(source), .chord(source), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        #expect(editor.idAllocator == V.advanced(initial, by: 7))
        try G.expectCycle(editor, before: before)
    }

    @Test func repeatedPayloadCopiesEachGraceIndependently() throws {
        let editor = ScoreEditor(score: V.score(elements: [
            G.decorated(), .rest(duration: .half), .rest(duration: .quarter),
        ]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = V.ids(V.elements(before))
        let source = try G.chord(before, 0)
        try editor.apply(PasteVoiceElements(at: V.location(1), elements: [.chord(source), .chord(source)]))
        // Each payload copy mints 6 (its own slot EID, then the 5-mint nested walk) before the next payload
        // starts, so the second copy's slot EID is the 7th mint overall, not the 4th.
        #expect(V.ids(V.elements(editor.score)) == [old[0], V.minted(initial, 1), V.minted(initial, 7), old[2]])
        let original = try G.chord(editor.score, 0)
        let first = try G.chord(editor.score, 1)
        let second = try G.chord(editor.score, 2)
        G.expectGrace(
            original,
            before: [source.graceNotesBefore.eid(at: 0)],
            after: [source.graceNotesAfter.eid(at: 0)],
        )
        #expect(first.notes.eid(at: 0) == V.minted(initial, 2))
        #expect(second.notes.eid(at: 0) == V.minted(initial, 8))
        #expect(first.notes.eid(at: 0) != second.notes.eid(at: 0))
        #expect(first.notes.eid(at: 0) != source.notes.eid(at: 0))
        #expect(second.notes.eid(at: 0) != source.notes.eid(at: 0))
        G.expectGrace(first, before: [V.minted(initial, 3)], after: [V.minted(initial, 4)])
        G.expectGrace(second, before: [V.minted(initial, 9)], after: [V.minted(initial, 10)])
        #expect(first == source)
        #expect(second == source)
        #expect(editor.idAllocator == V.advanced(initial, by: 12))
        try G.expectCycle(editor, before: before)
    }

    @Test("a pasted chord's notes are different notes")
    func pasteMintsNewNoteIdentifiers() throws {
        let editor = ScoreEditor(score: V.score(elements: [
            G.decorated(), .rest(duration: .half), .rest(duration: .quarter),
        ]))
        let source = try G.chord(editor.score, 0)
        try editor.apply(PasteVoiceElements(at: V.location(1), elements: [.chord(source), .chord(source)]))
        let first = try G.chord(editor.score, 1)
        let second = try G.chord(editor.score, 2)
        // The pasted chords' own notes, and their grace notes, are all disjoint from the source's — a
        // copy is different notes throughout, not just a different chord.
        let sourceNoteIDs = [source.notes.eid(at: 0)]
            + source.graceNotesBefore.values.map { $0.notes.eid(at: 0) }
            + source.graceNotesAfter.values.map { $0.notes.eid(at: 0) }
        for copy in [first, second] {
            let copyNoteIDs = [copy.notes.eid(at: 0)]
                + copy.graceNotesBefore.values.map { $0.notes.eid(at: 0) }
                + copy.graceNotesAfter.values.map { $0.notes.eid(at: 0) }
            #expect(Set(copyNoteIDs).isDisjoint(with: sourceNoteIDs))
        }
        // And the whole score's note identifiers — original plus both copies — are pairwise unique, the
        // invariant a duplicate would otherwise violate silently until the debug gate widens to see it.
        let allIDs = G.allNoteIDs(editor.score)
        #expect(allIDs.count == Set(allIDs).count)
        #expect(allIDs.count == 9) // 3 chords x (1 own note + 1 grace-before note + 1 grace-after note)
    }
}
