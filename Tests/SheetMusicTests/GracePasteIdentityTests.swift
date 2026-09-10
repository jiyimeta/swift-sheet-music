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
        G.expectGrace(copied, before: [V.minted(initial, 2)], after: [V.minted(initial, 3)])
        #expect(copied == source)
        #expect(editor.idAllocator == V.advanced(initial, by: 3))
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
        #expect(V.ids(V.elements(editor.score)) == [old[0], V.minted(initial, 1), V.minted(initial, 4), old[2]])
        let copied = try G.chord(editor.score, 1)
        let original = try G.chord(editor.score, 0)
        G.expectGrace(
            original,
            before: [source.graceNotesBefore.eid(at: 0)],
            after: [source.graceNotesAfter.eid(at: 0)],
        )
        G.expectGrace(copied, before: [V.minted(initial, 2)], after: [V.minted(initial, 3)])
        #expect(V.elements(editor.score).values == [
            .chord(source), .chord(source), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        #expect(editor.idAllocator == V.advanced(initial, by: 4))
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
        #expect(V.ids(V.elements(editor.score)) == [old[0], V.minted(initial, 1), V.minted(initial, 4), old[2]])
        let original = try G.chord(editor.score, 0)
        let first = try G.chord(editor.score, 1)
        let second = try G.chord(editor.score, 2)
        G.expectGrace(
            original,
            before: [source.graceNotesBefore.eid(at: 0)],
            after: [source.graceNotesAfter.eid(at: 0)],
        )
        G.expectGrace(first, before: [V.minted(initial, 2)], after: [V.minted(initial, 3)])
        G.expectGrace(second, before: [V.minted(initial, 5)], after: [V.minted(initial, 6)])
        #expect(first == source)
        #expect(second == source)
        #expect(editor.idAllocator == V.advanced(initial, by: 6))
        try G.expectCycle(editor, before: before)
    }
}
