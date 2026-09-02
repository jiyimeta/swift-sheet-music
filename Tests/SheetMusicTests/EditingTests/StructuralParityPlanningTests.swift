@testable import SheetMusicCore
import Testing

@Suite("Structural parity planning")
struct StructuralParityPlanningTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let m1 = MeasureRef(measureIndex: 1)

    @Test("each structural intent applies through the session and undoes")
    func appliesAndUndoes() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let before = session.score
        #expect(session.apply(.setLayoutBreak(at: Self.m1, kind: .line, enabled: true)))
        #expect(session.apply(.setBarLine(at: Self.m1, style: .double)))
        #expect(session.apply(.setRepeatBarLines(at: Self.m1, startRepeat: true, endRepeatCount: 2)))
        #expect(session.apply(.setMeasureRepeat(
            at: MeasureRef(measureIndex: 2), staff: StaffAddress(partIndex: 1, staffIndexInPart: 0), numMeasures: 2,
        )))
        #expect(session.apply(.moveToVoice(
            at: VoiceElementID(staff: Self.flute, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
            to: VoiceRef(staff: Self.flute, measureIndex: 0, voiceIndex: 1),
        )))
        for _ in 0 ..< 5 {
            #expect(session.undo())
        }
        #expect(session.score == before)
    }

    @Test("restating what the score already says plans to nothing")
    func restatingIsNothingToApply() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(!session.apply(.setLayoutBreak(at: Self.m1, kind: .line, enabled: false)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(!session.apply(.setBarLine(at: Self.m1, style: .normal)))
        #expect(!session.apply(.setRepeatBarLines(at: Self.m1, startRepeat: false, endRepeatCount: nil)))
        #expect(!session.apply(.setMeasureRepeat(at: Self.m1, staff: Self.flute, numMeasures: nil)))
    }

    @Test("a refused command surfaces its reason, not a crash")
    func refusalSurfaces() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(!session.apply(.setRepeatBarLines(at: Self.m1, startRepeat: false, endRepeatCount: 1)))
        #expect(session.lastRefusal?.reason == .invalidRepeatCount(1))
    }
}
