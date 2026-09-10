@testable import SheetMusicCore
import Testing

enum TupletIdentityFixtures {
    static let triplet = Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2)
    static let breath = VoiceElement.breath(Breath(kind: .breathMark(.comma), pause: 0))

    static func score(_ elements: [VoiceElement], tuplets: [Tuplet] = [triplet]) -> Score {
        VoiceIdentityFixtures.score([[Voice(elements: elements, tuplets: tuplets)]])
    }

    static func voice(_ score: Score, measure: Int = 0, voice: Int = 0) -> Voice {
        score.parts[0].staves[0].measures[measure].voices[voice]
    }

    static func mutate(_ score: inout Score, _ body: (inout Voice) -> Void) {
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in body(&staff.measures[0].voices[0]) }
        }
    }

    static func expectRoundTrip(
        _ editor: ScoreEditor, before: Score, after: Score, sourceLocation: SourceLocation = #_sourceLocation,
    ) throws {
        let allocator = editor.idAllocator
        VoiceIdentityFixtures.expectSameScore(editor.score, after, sourceLocation: sourceLocation)
        try editor.undo()
        VoiceIdentityFixtures.expectSameScore(editor.score, before, sourceLocation: sourceLocation)
        #expect(editor.idAllocator == allocator, sourceLocation: sourceLocation)
        try editor.redo()
        VoiceIdentityFixtures.expectSameScore(editor.score, after, sourceLocation: sourceLocation)
        #expect(editor.idAllocator == allocator, sourceLocation: sourceLocation)
        try editor.undo()
        VoiceIdentityFixtures.expectSameScore(editor.score, before, sourceLocation: sourceLocation)
        #expect(editor.idAllocator == allocator, sourceLocation: sourceLocation)
        try editor.redo()
        VoiceIdentityFixtures.expectSameScore(editor.score, after, sourceLocation: sourceLocation)
        #expect(editor.idAllocator == allocator, sourceLocation: sourceLocation)
    }
}
