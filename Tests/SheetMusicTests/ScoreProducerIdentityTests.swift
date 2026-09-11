import Foundation
import SheetMusicCore
import SheetMusicLoader
import SheetMusicMSCX
@testable import SheetMusicMusicXML
import SheetMusicXMLTools
import Testing

@Suite("Score producer identity")
struct ScoreProducerIdentityTests {
    private func bytes(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(TestResources.url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    private func bareScore() -> Score {
        Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "piano"), staves: [Staff(), Staff()]),
        ], systemMeasures: [SystemMeasure(), SystemMeasure()])
    }

    private func identifiers(_ score: Score) -> Set<EID> {
        var result = Set(score.parts.indices.map { score.parts.eid(at: $0) })
        for part in score.parts {
            result.formUnion(part.staves.indices.map { part.staves.eid(at: $0) })
        }
        result.formUnion(score.systemMeasures.indices.map { score.systemMeasures.eid(at: $0) })
        return result
    }

    @Test func loaderIdentifiesMSCX() throws {
        let score = try ScoreLoader.loadScore(bytes: bytes("midi01", "mscx"))
        #expect(!score.parts.isEmpty)
        #expect(!score.hasUnassignedIDs)
    }

    @Test func loaderIdentifiesMSCZ() throws {
        let score = try ScoreLoader.loadScore(bytes: bytes("midi01", "mscz"))
        #expect(!score.parts.isEmpty)
        #expect(!score.hasUnassignedIDs)
    }

    @Test func loaderIdentifiesMusicXML() throws {
        let score = try ScoreLoader.loadScore(bytes: bytes("glissando-wavy", "musicxml"))
        #expect(!score.parts.isEmpty)
        #expect(!score.hasUnassignedIDs)
    }

    @Test func loaderIdentifiesMIDI() throws {
        let score = try ScoreLoader.loadScore(bytes: bytes("midi01-ref", "mid"))
        #expect(!score.parts.isEmpty)
        #expect(!score.hasUnassignedIDs)
    }

    /// `ScoreLoader` already assigns unconditionally after every producer, so
    /// `loaderIdentifiesMSCX` above would pass even if `MSCXParser.parse` itself
    /// forgot its own chokepoint. This calls the parser directly.
    @Test func mscxParserIdentifiesItsScore() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        #expect(!score.parts.isEmpty)
        #expect(!score.hasUnassignedIDs)
    }

    @Test func musicXMLDecoderIdentifiesItsScore() throws {
        let root = try XMLTreeParser.parse(bytes("glissando-wavy", "musicxml"))
        let score = try Score.decodeMusicXML(root)
        #expect(!score.parts.isEmpty)
        #expect(!score.hasUnassignedIDs)
    }

    @Test func blankIdentifiesItsScore() {
        let score = Score.blank(BlankScoreTemplate(
            title: "Identity",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            measureCount: 2,
        ))
        #expect(score.parts.count == 1)
        #expect(score.systemMeasures.count == 2)
        #expect(!score.hasUnassignedIDs)
    }

    @Test func sessionInitUsesTheEditorsLiveAllocator() {
        let bare = bareScore()
        #expect(bare.hasUnassignedIDs)
        let session = ScoreEditSession(score: bare)
        #expect(!session.score.hasUnassignedIDs)
        #expect(session.idAllocator.counter == 5)
        #expect(!session.canUndo)
        #expect(session.lastAffectedLocation == nil)
    }

    @Test func directEditorIsIdentifiedBeforeAnyApply() {
        let editor = ScoreEditor(score: bareScore())
        #expect(!editor.score.hasUnassignedIDs)
        #expect(editor.idAllocator.counter == 5)
        #expect(!editor.canUndo)
        #expect(editor.lastAffectedLocation == nil)
    }

    /// Catches a fixed deterministic allocator reused from its initial value for each load.
    /// Does not catch a shared allocator: its advancing counter also produces disjoint sets.
    /// D4's ban on shared allocators is enforced by review, not by this test.
    ///
    /// Fixture is `multiPartMixedStaves`, not `midi01`: it carries no `<eid>` of its own on
    /// any part, staff declaration, or measure, so every identifier `identifiers(_:)` collects
    /// is chokepoint-minted rather than file-persisted. `midi01.mscx` would no longer work here
    /// since Task 3 of the P4 plan made its staff declaration (`C_C`) and first-measure column
    /// (`D_D`) round-trip — those decode to the *same* identifiers on every load by design, which
    /// is the feature, not a regression, but it would make this disjointness assertion fail for
    /// the wrong reason.
    @Test func repeatedLoadsHaveDisjointIdentifiers() throws {
        let data = try bytes("multiPartMixedStaves", "mscx")
        let first = try identifiers(ScoreLoader.loadScore(bytes: data))
        let second = try identifiers(ScoreLoader.loadScore(bytes: data))
        #expect(!first.isEmpty)
        #expect(!second.isEmpty)
        #expect(first.isDisjoint(with: second))
    }
}
