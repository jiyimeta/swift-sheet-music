@testable import SheetMusicCore
import Testing

@Suite("DuplicateRange intent")
struct DuplicateRangeIntentTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    @Test("the intent applies as one undo step")
    func appliesAsOneStep() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let before = session.score
        #expect(session.apply(.duplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(0, 2),
        ))))
        #expect(session.score != before)
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before.stableFingerprint)
    }

    @Test("an unresolvable range refuses with targetNotFound")
    func refuses() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(!session.apply(.duplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(9, 0),
        ))))
        guard case .targetNotFound = session.lastRefusal?.reason else {
            Issue.record("expected targetNotFound, got \(String(describing: session.lastRefusal?.reason))")
            return
        }
    }

    @Test("element identifiers survive apply, undo and redo")
    func identityRoundTrips() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let before = session.score.stableFingerprint
        #expect(session.apply(.duplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(0, 2),
        ))))
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
        #expect(session.redo())
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }

    @Test("the command and the intent produce the same score")
    func agreesWithCommand() throws {
        var direct = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)))
            .apply(to: &direct)
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(session.apply(.duplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(0, 2),
        ))))
        #expect(direct.stableFingerprint == session.score.stableFingerprint)
    }
}
