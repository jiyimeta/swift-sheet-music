@testable import SheetMusicCore
import Testing

@Suite("Tuplet identity structural boundaries")
struct TupletIdentityBoundaryTests {
    private typealias F = TupletIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    @Test func keyInsertionKeepsClefEndpointAndUndoRestoresExactTuplet() throws {
        let editor = ScoreEditor(score: F.score([
            .clef(Clef(concertClefType: "G")), V.chord(), V.chord(),
        ]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(SetKeySignature(measureIndex: 0, concertKey: 2))
        let voice = F.voice(editor.score)
        #expect(voice.tuplets[0] == F.voice(before).tuplets[0])
        #expect(voice.tuplets.eid(at: 0) == F.voice(before).tuplets.eid(at: 0))
        #expect(voice.tupletSpans[0].startIndex == 0)
        #expect(voice.tupletSpans[0].endIndex == 3)
        #expect(editor.idAllocator == V.advanced(initial, by: 1))
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test(arguments: [false, true])
    func keyEndpointRemovalRestoresTupletIncludingMemberlessCase(markOnly: Bool) throws {
        let voice = Voice(elements: [.keySignature(KeySignature(concertKey: 2)), V.chord(), V.chord()], tuplets: [
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: markOnly ? 0 : 2),
        ])
        let editor = ScoreEditor(score: V.score([[Voice(elements: [.rest(duration: .measure)])], [voice]]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(RemoveKeySignature(measureIndex: 1))
        let after = F.voice(editor.score, measure: 1)
        if markOnly {
            #expect(after.tuplets.isEmpty)
        } else {
            #expect(after.tuplets.eid(at: 0) == F.voice(before, measure: 1).tuplets.eid(at: 0))
            #expect(after.tuplets[0].first == .element(after.elements.eid(at: 0)))
            #expect(after.tuplets[0].last == .element(after.elements.eid(at: 1)))
        }
        #expect(editor.idAllocator == initial)
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func removingInnerTupletRetargetsSurvivingOuterEndpointInward() throws {
        let editor = ScoreEditor(score: F.score([V.chord(), V.chord(), V.chord(), V.chord()], tuplets: [
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 2),
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2),
        ]))
        let before = editor.score
        let old = F.voice(before)
        try editor.apply(RemoveTuplet(at: V.location(1)))
        let voice = F.voice(editor.score)
        #expect(voice.tuplets.count == 1)
        #expect(voice.tuplets.eid(at: 0) == old.tuplets.eid(at: 1))
        #expect(voice.tuplets[0].first == .element(old.elements.eid(at: 0)))
        #expect(voice.tuplets[0].last == .element(old.elements.eid(at: 1)))
        #expect(voice.tupletSpans[0].endIndex == 1)
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func moveKeepsDestinationTupletIdentity() throws {
        let source = Voice(elements: [V.chord(.half), .rest(duration: .half)])
        let destination = Voice(elements: [
            .rest(duration: .quarter), .rest(duration: .quarter),
            V.chord(.eighth), V.chord(.eighth), V.chord(.eighth), .rest(duration: .quarter),
        ], tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 4)])
        let editor = ScoreEditor(score: V.score([[source, destination]]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(MoveToVoice(
            at: V.location(0), to: VoiceRef(staff: V.staff, measureIndex: 0, voiceIndex: 1),
        ))
        let voice = F.voice(editor.score, voice: 1)
        #expect(voice.tuplets[0] == F.voice(before, voice: 1).tuplets[0])
        #expect(voice.tuplets.eid(at: 0) == F.voice(before, voice: 1).tuplets.eid(at: 0))
        #expect(voice.tupletSpans[0].startIndex == 1)
        #expect(voice.tupletSpans[0].endIndex == 3)
        #expect(editor.idAllocator == V.advanced(initial, by: 1))
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func moveLeavesMarkOnlyTupletOnKeptUntimedSlots() throws {
        let source = Voice(elements: [V.chord(.half), .rest(duration: .half)])
        let destination = Voice(elements: [
            .rest(duration: .quarter), F.breath, .rest(duration: .quarter), .rest(duration: .half),
        ], tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 1)])
        let editor = ScoreEditor(score: V.score([[source, destination]]))
        let before = editor.score
        try editor.apply(MoveToVoice(
            at: V.location(0), to: VoiceRef(staff: V.staff, measureIndex: 0, voiceIndex: 1),
        ))
        let voice = F.voice(editor.score, voice: 1)
        let mark = F.voice(before, voice: 1).elements.eid(at: 1)
        #expect(voice.tuplets[0] == F.voice(before, voice: 1).tuplets[0])
        #expect(voice.tuplets[0].first == .element(mark))
        #expect(voice.tuplets[0].last == .element(mark))
        let retainsBreath = voice.elements.contains { $0 == F.breath }
        #expect(retainsBreath)
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }
}
