@testable import SheetMusicCore
import Testing

@Suite("SetBeamVisible")
struct SetBeamVisibleTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    private static func chord(_ score: Score, _ element: Int) -> Chord? {
        if case let .chord(c)? = score[slot(element)] { c } else { nil }
    }

    @Test("the flag is written on the chord addressed, and nothing else moves")
    func writesFlag() throws {
        var score = EditingFixtures.twoBeamedEighths() // [ts, C4 e, D4 e, r q, r h]
        _ = try SetBeamVisible(at: Self.slot(1), visible: false).apply(to: &score)
        let lead = try #require(Self.chord(score, 1))
        #expect(!lead.beamVisible)
        #expect(lead.visible && lead.stemVisible && lead.notes[0].visible)
        #expect(Self.chord(score, 2)?.beamVisible == true)
    }

    @Test("current reads the group LEADER's flag whichever member is named")
    func currentReadsTheLeader() throws {
        var score = EditingFixtures.twoBeamedEighths()
        #expect(SetBeamVisible.leader(of: Self.slot(2), in: score) == Self.slot(1))
        _ = try SetBeamVisible(at: Self.slot(1), visible: false).apply(to: &score)
        #expect(SetBeamVisible.current(at: Self.slot(1), in: score) == false)
        #expect(SetBeamVisible.current(at: Self.slot(2), in: score) == false) // the follower answers for its leader
        #expect(SetBeamVisible.current(at: Self.slot(3), in: score) == nil) // a rest
    }

    @Test("undo restores the flag the chord had")
    func inverseRestores() throws {
        var score = EditingFixtures.twoBeamedEighths()
        let before = score
        let inverse = try SetBeamVisible(at: Self.slot(1), visible: false).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("true shows a hidden beam again")
    func shows() throws {
        var score = EditingFixtures.twoBeamedEighths()
        _ = try SetBeamVisible(at: Self.slot(1), visible: false).apply(to: &score)
        _ = try SetBeamVisible(at: Self.slot(1), visible: true).apply(to: &score)
        #expect(score == EditingFixtures.twoBeamedEighths())
    }

    @Test("a chord in no beam group, a rest, an untimed element and a missing slot are refused")
    func refusals() {
        var score = EditingFixtures.twoBeamedEighths()
        let before = score
        var lone = EditingFixtures.chordAtIndex1() // a lone quarter — beam level 0
        let unbeamed = #expect(throws: SheetMusicError.self) {
            _ = try SetBeamVisible(at: Self.slot(1), visible: false).apply(to: &lone)
        }
        #expect(Self.reason(of: unbeamed) == .notBeamed(at: Self.slot(1)))
        let rest = #expect(throws: SheetMusicError.self) {
            _ = try SetBeamVisible(at: Self.slot(3), visible: false).apply(to: &score)
        }
        #expect(Self.reason(of: rest) == .wrongElementKind(at: Self.slot(3), expected: .chord))
        #expect(throws: SheetMusicError.self) {
            _ = try SetBeamVisible(at: Self.slot(0), visible: false).apply(to: &score)
        }
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetBeamVisible(at: Self.slot(9), visible: false).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(9)))
        #expect(score == before)
        #expect(lone == EditingFixtures.chordAtIndex1())
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
