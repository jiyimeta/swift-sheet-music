@testable import SheetMusicCore
import Testing

@Suite("Spanner planning")
struct SpannerPlanningTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func range(_ measure: Int, _ from: Int, _ to: Int) -> VoiceElementRange {
        VoiceElementRange(start: slot(measure, from), end: slot(measure, to))
    }

    @Test("every spanner intent applies through the session and undoes")
    func appliesAndUndoes() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let before = session.score
        // Bar 0 is [ts, C4, D4, r, r]; each insert shifts the later indices of that bar by one, so each step
        // below names the index as the previous step left it.
        #expect(session.apply(.setSlur(over: Self.range(0, 1, 2)))) // no shift — chord-anchored
        #expect(session.apply(.setHairpin(over: Self.range(0, 1, 2), subtype: .crescendo)))
        #expect(session.apply(.setPedal(over: Self.range(0, 2, 3))))
        #expect(session.apply(.setOttava(over: Self.range(0, 3, 4), subtype: .eightVB)))
        #expect(session.apply(.setTextLine(over: Self.range(0, 4, 5), text: "rall.")))
        #expect(session.apply(.setTrill(over: Self.range(0, 5, 6), type: .trill)))
        #expect(session.apply(.setVibrato(over: Self.range(0, 6, 7), type: .guitarVibrato)))
        #expect(session.apply(.setPalmMute(over: Self.range(0, 7, 8))))
        #expect(session.apply(.setLetRing(over: Self.range(0, 8, 9))))
        #expect(session.apply(.setVolta(over: Self.range(2, 0, 1), endings: [1], text: "1.")))
        #expect(session.apply(.removeSpanner(at: Self.slot(0, 1), kind: .hairpin)))
        for _ in 0 ..< 11 {
            #expect(session.undo())
        }
        #expect(session.score == before)
    }

    /// The departure from "restating is nil": re-issuing a spanner intent is a REFUSAL, not `.nothingToApply`.
    @Test("re-issuing a spanner intent refuses as duplicateSpanner and pushes no undo entry")
    func restatingIsARefusal() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(session.apply(.setPedal(over: Self.range(2, 0, 1))))
        let afterFirst = session.score
        #expect(!session.apply(.setPedal(over: Self.range(2, 1, 2))))
        #expect(session.lastRefusal?.reason == .duplicateSpanner(at: Self.slot(2, 1), kind: .pedal))
        #expect(session.score == afterFirst)
        #expect(session.undo())
        #expect(session.score == EditingFixtures.parityFixture())
    }

    @Test("a refused command surfaces its reason, not nothingToApply and not a crash")
    func refusalSurfaces() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(!session.apply(.removeSpanner(at: Self.slot(0, 1), kind: .slur)))
        #expect(session.lastRefusal?.reason == .noSpannerAtLocation(Self.slot(0, 1)))
        #expect(!session.apply(.setSlur(over: Self.range(2, 0, 0))))
        #expect(session.lastRefusal?.reason == .noNextChord(at: Self.slot(2, 0)))
        #expect(!session.apply(.setVolta(
            over: VoiceElementRange(start: Self.slot(9, 0), end: Self.slot(9, 0)), endings: [], text: nil,
        )))
    }
}
