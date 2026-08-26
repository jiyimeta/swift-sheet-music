@testable import SheetMusicCore
import Testing

@Suite("ScoreEditSession measure intents")
struct ScoreEditSessionMeasureTests {
    private func session() -> ScoreEditSession {
        ScoreEditSession(score: Score.blank(BlankScoreTemplate(
            title: "t", instrumentID: "piano", staves: [.init(clefType: "G")], measureCount: 2,
        )))
    }

    @Test("insertMeasure applies and undoes")
    func insertMeasure() {
        let session = session()
        let original = session.score
        #expect(session.apply(.insertMeasure(at: 2)))
        #expect(session.score.parts[0].staves[0].measures.count == 3)
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("deleteMeasure applies and undoes")
    func deleteMeasure() {
        let session = session()
        let original = session.score
        #expect(session.apply(.deleteMeasure(at: 0)))
        #expect(session.score.parts[0].staves[0].measures.count == 1)
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("deleteMeasure on the only bar refuses with a recorded refusal")
    func refusalSurfaces() {
        let session = ScoreEditSession(score: Score.blank(BlankScoreTemplate(
            title: "t", instrumentID: "piano", staves: [.init(clefType: "G")], measureCount: 1,
        )))
        #expect(!session.apply(.deleteMeasure(at: 0)))
        #expect(session.lastRefusal?.reason == .cannotDeleteOnlyMeasure)
    }
}
