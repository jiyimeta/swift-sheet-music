@testable import SheetMusicCore
import Testing

@Suite("Tuplet identity editing")
struct TupletIdentityEditingTests {
    private typealias F = TupletIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    @Test(arguments: [0, 1])
    func dynamicInsertionFollowsEndpointsAndRemovalRestoresThem(index: Int) throws {
        let editor = ScoreEditor(score: F.score([V.chord(), V.chord(), V.chord()]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = F.voice(before)
        try editor.apply(SetDynamic(at: V.location(index), subtype: "f"))
        let inserted = editor.score
        #expect(F.voice(inserted).tuplets[0] == old.tuplets[0])
        #expect(F.voice(inserted).tuplets.eid(at: 0) == old.tuplets.eid(at: 0))
        #expect(F.voice(inserted).tupletSpans[0].startIndex == (index == 0 ? 1 : 0))
        #expect(F.voice(inserted).tupletSpans[0].endIndex == 3)
        #expect(F.voice(inserted).elements.eid(at: index) == V.minted(initial, 1))
        #expect(editor.idAllocator == V.advanced(initial, by: 1))
        try F.expectRoundTrip(editor, before: before, after: inserted)
        try editor.apply(SetDynamic(at: V.location(index + 1), subtype: nil))
        V.expectSameScore(editor.score, before)
        #expect(editor.idAllocator == V.advanced(initial, by: 1))
        try F.expectRoundTrip(editor, before: inserted, after: before)
    }

    @Test func deletingFirstChordRetargetsToFreshRestAndReplaysWithoutMinting() throws {
        let editor = ScoreEditor(score: F.score([V.chord(), V.chord(), V.chord()]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(DeleteVoiceElement(at: V.location(0)))
        let voice = F.voice(editor.score)
        #expect(voice.elements[0].isRest)
        #expect(voice.tuplets.eid(at: 0) == F.voice(before).tuplets.eid(at: 0))
        #expect(voice.tuplets[0].first == .element(V.minted(initial, 1)))
        #expect(voice.tuplets[0].last == F.voice(before).tuplets[0].last)
        #expect(editor.idAllocator == V.advanced(initial, by: 1))
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func createTupletMintsMembersBeforeItsOwnIdentity() throws {
        let editor = ScoreEditor(score: F.score([
            V.chord(), .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
        ], tuplets: []))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(CreateTuplet(at: V.location(0), actualNotes: 3, normalNotes: 2))
        let voice = F.voice(editor.score)
        #expect(Array(V.ids(voice.elements).prefix(3)) == [
            F.voice(before).elements.eid(at: 0), V.minted(initial, 1), V.minted(initial, 2),
        ])
        #expect(voice.tuplets.eid(at: 0) == V.minted(initial, 3))
        #expect(voice.tuplets[0].first == .element(F.voice(before).elements.eid(at: 0)))
        #expect(voice.tuplets[0].last == .element(V.minted(initial, 2)))
        #expect(editor.idAllocator == V.advanced(initial, by: 3))
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func removeTupletRemovesItsIdentityAndRestoresRawEndpointsOnUndo() throws {
        let editor = ScoreEditor(score: F.score([V.chord(), V.chord(), V.chord()]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(RemoveTuplet(at: V.location(0)))
        #expect(F.voice(editor.score).tuplets.isEmpty)
        #expect(V.ids(F.voice(editor.score).elements) == [F.voice(before).elements.eid(at: 0)])
        #expect(editor.idAllocator == initial)
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test(arguments: [false, true])
    func removingLastMarkRetargetsInwardOrDropsMemberlessTuplet(markOnly: Bool) throws {
        let tuplet = Tuplet(normalNotes: 2, actualNotes: 3, startIndex: markOnly ? 1 : 0, endIndex: 1)
        let editor = ScoreEditor(score: F.score([V.chord(), F.breath, V.chord()], tuplets: [tuplet]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(SetBreath(after: V.location(0), kind: nil, pause: 0))
        let voice = F.voice(editor.score)
        #expect(voice.elements.count == 2)
        if markOnly {
            #expect(voice.tuplets.isEmpty)
        } else {
            #expect(voice.tuplets.eid(at: 0) == F.voice(before).tuplets.eid(at: 0))
            #expect(voice.tuplets[0].first == .element(voice.elements.eid(at: 0)))
            #expect(voice.tuplets[0].last == .element(voice.elements.eid(at: 0)))
            #expect(voice.tupletSpans[0].endIndex == 0)
        }
        #expect(editor.idAllocator == initial)
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test(arguments: [false, true])
    func literalRemovalUsesTheSameInwardRule(markOnly: Bool) {
        var voice = Voice(elements: [V.chord(), F.breath, V.chord()], tuplets: [
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: markOnly ? 1 : 0, endIndex: 1),
        ])
        MeasureStructure.removeElements(in: &voice) { if case .breath = $0 { true } else { false } }
        if markOnly {
            #expect(voice.tuplets.isEmpty)
        } else {
            #expect(voice.tuplets[0].first == .index(0))
            #expect(voice.tuplets[0].last == .index(0))
        }
        #expect(voice.elements.count == 2)
    }
}
