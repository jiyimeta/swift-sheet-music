@testable import SheetMusicCore
import Testing

@Suite("Tuplet identity at trailing barlines")
struct TupletIdentityBarLineTests {
    private typealias F = TupletIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    @Test func removingTrailingEndpointRetargetsInwardAndRestoresExactly() throws {
        let editor = ScoreEditor(score: F.score([
            V.chord(.half), V.chord(.half), .barLine(BarLine(subtype: "double")),
        ]))
        let before = editor.score
        let original = F.voice(before)
        let allocator = editor.idAllocator
        try editor.apply(SetBarLine(at: MeasureRef(measureIndex: 0), style: .normal))
        let after = F.voice(editor.score)
        #expect(after.elements.count == 2)
        #expect(after.tuplets.count == 1)
        #expect(after.tuplets.eid(at: 0) == original.tuplets.eid(at: 0))
        #expect(after.tuplets[0].first == .element(original.elements.eid(at: 0)))
        #expect(after.tuplets[0].last == .element(original.elements.eid(at: 1)))
        #expect(after.tupletSpans[0].startIndex == 0)
        #expect(after.tupletSpans[0].endIndex == 1)
        #expect(editor.idAllocator == allocator)
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func removingOnlyBarlineMemberDropsTupletAndRestoresExactly() throws {
        let editor = ScoreEditor(score: F.score([
            V.chord(.whole), .barLine(BarLine(subtype: "double")),
        ], tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 1)]))
        let before = editor.score
        let original = F.voice(before)
        let allocator = editor.idAllocator
        try editor.apply(SetBarLine(at: MeasureRef(measureIndex: 0), style: .normal))
        let after = F.voice(editor.score)
        #expect(after.elements.count == 1)
        #expect(after.elements.eid(at: 0) == original.elements.eid(at: 0))
        #expect(after.tuplets.isEmpty)
        #expect(editor.idAllocator == allocator)
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }
}
