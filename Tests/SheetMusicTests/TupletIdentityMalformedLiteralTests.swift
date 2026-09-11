@testable import SheetMusicCore
import Testing

@Suite("Malformed literal tuplet adoption")
struct TupletIdentityMalformedLiteralTests {
    private typealias V = VoiceIdentityFixtures

    private var literal: Score {
        TupletIdentityFixtures.score([V.chord(), V.chord(), V.chord()], tuplets: [
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 3),
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 0),
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2),
        ])
    }

    @Test func editorDropsUnusableLiteralTupletsBeforeMinting() throws {
        let editor = ScoreEditor(score: literal)
        try expectValidTupletOnly(editor.score)
        // Part + staff + three (element, own note) pairs + one valid tuplet + column = ten mints.
        #expect(editor.idAllocator.counter == 10)
    }

    @Test func bareNoOpDropsUnusableLiteralTupletsBeforeMinting() throws {
        var score = literal
        try ReplaceVoiceElement(at: V.location(1), with: V.chord(), identity: .same).apply(to: &score)
        try expectValidTupletOnly(score)
    }

    private func expectValidTupletOnly(_ score: Score, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let voice = TupletIdentityFixtures.voice(score)
        try #require(voice.tuplets.count == 1, sourceLocation: sourceLocation)
        let actor = score.parts.eid(at: 0).first
        #expect(score.parts.eid(at: 0) == EID(first: actor, second: 1), sourceLocation: sourceLocation)
        #expect(score.parts[0].staves.eid(at: 0) == EID(first: actor, second: 2), sourceLocation: sourceLocation)
        // Each chord mints its own note right after its element slot, so slot ids land on odd counters.
        let memberIDs = [3, 5, 7].map { EID(first: actor, second: UInt64($0)) }
        #expect(V.ids(voice.elements) == memberIDs, sourceLocation: sourceLocation)
        #expect(voice.tuplets.eid(at: 0) == EID(first: actor, second: 9), sourceLocation: sourceLocation)
        #expect(voice.tuplets[0] == Tuplet(
            normalNotes: 2, actualNotes: 3, first: memberIDs[0], last: memberIDs[2],
        ), sourceLocation: sourceLocation)
        #expect(score.systemMeasures.eid(at: 0) == EID(first: actor, second: 10), sourceLocation: sourceLocation)
        #expect(!score.hasUnassignedIDs, sourceLocation: sourceLocation)
    }
}
