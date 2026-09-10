@testable import SheetMusicCore
import Testing

@Suite("Grace identity through chord edits")
struct GraceEditIdentityTests {
    private typealias V = VoiceIdentityFixtures
    private typealias G = GraceTransportFixtures

    @Test func durationKeepsBothGraceLists() throws {
        let editor = ScoreEditor(score: V.score(elements: [G.decorated(.half), .rest(duration: .half)]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = V.ids(V.elements(before))
        let original = try G.chord(before, 0)
        try editor.apply(SetChordDuration(at: V.location(0), duration: .quarter))
        let result = try G.chord(editor.score, 0)
        G.expectGrace(
            result,
            before: [original.graceNotesBefore.eid(at: 0)],
            after: [original.graceNotesAfter.eid(at: 0)],
        )
        #expect(result.duration == .quarter)
        #expect(V.ids(V.elements(editor.score)) == [old[0], V.minted(initial, 1), old[1]])
        #expect(editor.idAllocator == V.advanced(initial, by: 1))
        try G.expectCycle(editor, before: before)
    }

    @Test func respellKeepsBothGraceLists() throws {
        let editor = ScoreEditor(score: V.score(elements: [G.decorated(.whole)]))
        let before = editor.score
        let initial = editor.idAllocator
        let original = try G.chord(before, 0)
        let range = VoiceElementRange(start: V.location(0), end: V.location(0))
        try editor.apply(RespellRange(over: range, mode: .preferFlats))
        let result = try G.chord(editor.score, 0)
        G.expectGrace(
            result,
            before: [original.graceNotesBefore.eid(at: 0)],
            after: [original.graceNotesAfter.eid(at: 0)],
        )
        #expect(result.notes[0].pitch == 63)
        #expect(result.notes[0].tpc == 11)
        #expect(result.graceNotesBefore.values == original.graceNotesBefore.values)
        #expect(result.graceNotesAfter.values == original.graceNotesAfter.values)
        #expect(V.voiceIDs(editor.score) == V.voiceIDs(before))
        #expect(editor.idAllocator == initial)
        try G.expectCycle(editor, before: before)
    }

    @Test func tieKeepsGraceIdentityOnBothChords() throws {
        let editor = ScoreEditor(score: V.score(elements: [G.decorated(.half), G.decorated(.half)]))
        let before = editor.score
        let initial = editor.idAllocator
        let source = NoteID(
            staff: V.staff,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
            noteIndexInChord: 0,
        )
        let target = NoteID(
            staff: V.staff,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 1,
            noteIndexInChord: 0,
        )
        try editor.apply(SetTie(from: source, to: target, sourceTieForward: 1, targetTieBack: 1))
        for index in 0 ..< 2 {
            let original = try G.chord(before, index)
            let result = try G.chord(editor.score, index)
            G.expectGrace(
                result,
                before: [original.graceNotesBefore.eid(at: 0)],
                after: [original.graceNotesAfter.eid(at: 0)],
            )
        }
        #expect(editor.score[source]?.tieForward == 1)
        #expect(editor.score[target]?.tieBack == 1)
        #expect(V.voiceIDs(editor.score) == V.voiceIDs(before))
        #expect(editor.idAllocator == initial)
        try G.expectCycle(editor, before: before)
    }

    @Test func deleteDropsGraceAndUndoRestoresExactIdentity() throws {
        let editor = ScoreEditor(score: V.score(elements: [G.decorated(.whole)]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(DeleteVoiceElement(at: V.location(0)))
        #expect(V.ids(V.elements(editor.score)) == [V.minted(initial, 1)])
        let rest = try G.chord(editor.score, 0)
        #expect(rest.notes.isEmpty)
        G.expectGrace(rest, before: [], after: [])
        #expect(editor.idAllocator == V.advanced(initial, by: 1))
        try G.expectCycle(editor, before: before)
    }
}
