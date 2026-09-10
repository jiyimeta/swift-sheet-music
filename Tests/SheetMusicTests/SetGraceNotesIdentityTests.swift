@testable import SheetMusicCore
import Testing

@Suite("SetGraceNotes identity")
struct SetGraceNotesIdentityTests {
    private typealias F = GraceIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    @Test func pureRemovalKeepsSurvivorsWithoutMinting() throws {
        let a = F.grace(), b = F.grace(61), c = F.grace(63)
        let editor = ScoreEditor(score: F.score(before: [a, b, c], after: [c, b, a]))
        let before = editor.score
        let old = try F.chord(before)
        let initial = editor.idAllocator
        try editor.apply(SetGraceNotes(at: V.location(0), before: [a, c], after: [c, a]))
        let result = try F.chord(editor.score)
        #expect(F.ids(result.graceNotesBefore) == [old.graceNotesBefore.eid(at: 0), old.graceNotesBefore.eid(at: 2)])
        #expect(F.ids(result.graceNotesAfter) == [old.graceNotesAfter.eid(at: 0), old.graceNotesAfter.eid(at: 2)])
        #expect(result.graceNotesBefore.values == [a, c])
        #expect(result.graceNotesAfter.values == [c, a])
        #expect(editor.idAllocator == initial)
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func pureReorderMovesIdentityWithValuesWithoutMinting() throws {
        let a = F.grace(), b = F.grace(61)
        let editor = ScoreEditor(score: F.score(before: [a, b], after: [b, a]))
        let before = editor.score
        let old = try F.chord(before)
        let initial = editor.idAllocator
        try editor.apply(SetGraceNotes(at: V.location(0), before: [b, a], after: [a, b]))
        let result = try F.chord(editor.score)
        #expect(F.ids(result.graceNotesBefore) == [old.graceNotesBefore.eid(at: 1), old.graceNotesBefore.eid(at: 0)])
        #expect(F.ids(result.graceNotesAfter) == [old.graceNotesAfter.eid(at: 1), old.graceNotesAfter.eid(at: 0)])
        #expect(result.graceNotesBefore.values == [b, a])
        #expect(result.graceNotesAfter.values == [a, b])
        #expect(editor.idAllocator == initial)
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func addOnePreservesUnchangedPrefixInBothLists() throws {
        let a = F.grace(), b = F.grace(61), c = F.grace(63)
        let editor = ScoreEditor(score: F.score(before: [a, b], after: [b, a]))
        let before = editor.score
        let old = try F.chord(before)
        let initial = editor.idAllocator
        try editor.apply(SetGraceNotes(at: V.location(0), before: [a, b, c], after: [b, a, c]))
        let result = try F.chord(editor.score)
        #expect(F.ids(result.graceNotesBefore) == F.ids(old.graceNotesBefore) + [V.minted(initial, 1)])
        #expect(F.ids(result.graceNotesAfter) == F.ids(old.graceNotesAfter) + [V.minted(initial, 2)])
        #expect(result.graceNotesBefore.values == [a, b, c])
        #expect(result.graceNotesAfter.values == [b, a, c])
        #expect(editor.idAllocator == V.advanced(initial, by: 2))
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func duplicateShrinkKeepsFirstEqualInBothLists() throws {
        let a = F.grace()
        let editor = ScoreEditor(score: F.score(before: [a, a], after: [a, a]))
        let before = editor.score
        let old = try F.chord(before)
        let initial = editor.idAllocator
        try editor.apply(SetGraceNotes(at: V.location(0), before: [a], after: [a]))
        let result = try F.chord(editor.score)
        #expect(F.ids(result.graceNotesBefore) == [old.graceNotesBefore.eid(at: 0)])
        #expect(F.ids(result.graceNotesAfter) == [old.graceNotesAfter.eid(at: 0)])
        #expect(result.graceNotesBefore.values == [a])
        #expect(result.graceNotesAfter.values == [a])
        #expect(editor.idAllocator == initial)
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func matchingReorderAddRemoveAndRestatementInBothLists() throws {
        let a = F.grace(59), b = F.grace(61), c = F.grace(63)
        let editor = ScoreEditor(score: F.score(before: [a, b], after: [b, a]))
        let original = editor.score
        let old = try F.chord(original)
        let initial = editor.idAllocator
        try editor.apply(SetGraceNotes(at: V.location(0), before: [b, c, a], after: [a, c]))
        let edited = editor.score
        let result = try F.chord(edited)
        #expect(F.ids(result.graceNotesBefore) == [
            old.graceNotesBefore.eid(at: 1), V.minted(initial, 1), old.graceNotesBefore.eid(at: 0),
        ])
        #expect(F.ids(result.graceNotesAfter) == [old.graceNotesAfter.eid(at: 1), V.minted(initial, 2)])
        #expect(result.graceNotesBefore.values == [b, c, a])
        #expect(result.graceNotesAfter.values == [a, c])
        #expect(editor.idAllocator == V.advanced(initial, by: 2))
        try TupletIdentityFixtures.expectRoundTrip(editor, before: original, after: edited)
        let counter = editor.idAllocator
        try editor.apply(SetGraceNotes(at: V.location(0), before: [b, c, a], after: [a, c]))
        V.expectSameScore(editor.score, edited)
        #expect(editor.idAllocator == counter)
    }

    @Test func duplicatesConsumeFirstUnusedEqualInEachList() throws {
        let a = F.grace(), b = F.grace(61)
        let editor = ScoreEditor(score: F.score(before: [a, b, a], after: [a, a]))
        let before = editor.score
        let old = try F.chord(before)
        let initial = editor.idAllocator
        try editor.apply(SetGraceNotes(at: V.location(0), before: [a, a, a, b], after: [a, a, a]))
        let result = try F.chord(editor.score)
        #expect(F.ids(result.graceNotesBefore) == [
            old.graceNotesBefore.eid(at: 0), old.graceNotesBefore.eid(at: 2),
            V.minted(initial, 1), old.graceNotesBefore.eid(at: 1),
        ])
        #expect(F.ids(result.graceNotesAfter) == F.ids(old.graceNotesAfter) + [V.minted(initial, 2)])
        #expect(editor.idAllocator == V.advanced(initial, by: 2))
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test(arguments: 0 ..< 4)
    func eachValueChangeMintsInBothLists(_ field: Int) throws {
        let originalGrace = F.grace()
        var changed = originalGrace
        switch field {
        case 0: changed.graceType = .appoggiatura
        case 1: changed.duration = .sixteenth
        case 2: changed.preservedMarkup = [PreservedXML(name: "unknown")]
        default: changed.notes = [Note(pitch: 61, tpc: 13)]
        }
        let editor = ScoreEditor(score: F.score(before: [originalGrace], after: [originalGrace]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(SetGraceNotes(at: V.location(0), before: [changed], after: [changed]))
        let result = try F.chord(editor.score)
        #expect(F.ids(result.graceNotesBefore) == [V.minted(initial, 1)])
        #expect(F.ids(result.graceNotesAfter) == [V.minted(initial, 2)])
        #expect(result.graceNotesBefore.values == [changed])
        #expect(result.graceNotesAfter.values == [changed])
        #expect(editor.idAllocator == V.advanced(initial, by: 2))
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func clearRestoresExactIDsAndInverseTypeWithoutMinting() throws {
        var score = F.score(before: [F.grace(), F.grace(61)], after: [F.grace(63)])
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let before = score
        let initial = ids
        let inverse = try SetGraceNotes(at: V.location(0), before: [], after: []).apply(to: &score, ids: &ids)
        #expect(inverse is SetGraceNotes)
        let after = score
        #expect(try F.chord(score).graceNotesBefore.isEmpty)
        #expect(try F.chord(score).graceNotesAfter.isEmpty)
        for _ in 0 ..< 2 {
            let redo = try inverse.apply(to: &score, ids: &ids)
            #expect(redo is SetGraceNotes)
            V.expectSameScore(score, before)
            try redo.apply(to: &score, ids: &ids)
            V.expectSameScore(score, after)
            #expect(ids == initial)
        }
    }

    @Test func movingValueBetweenListsMintsInsteadOfMatchingAcrossLists() throws {
        let a = F.grace(), b = F.grace(61)
        let editor = ScoreEditor(score: F.score(before: [a], after: [b]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(SetGraceNotes(at: V.location(0), before: [b], after: [a]))
        let result = try F.chord(editor.score)
        #expect(F.ids(result.graceNotesBefore) == [V.minted(initial, 1)])
        #expect(F.ids(result.graceNotesAfter) == [V.minted(initial, 2)])
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
    }
}
