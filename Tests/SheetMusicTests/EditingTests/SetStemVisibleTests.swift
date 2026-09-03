@testable import SheetMusicCore
import Testing

@Suite("SetStemVisible")
struct SetStemVisibleTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    private static func chord(_ score: Score, _ element: Int) -> Chord? {
        if case let .chord(c)? = score[slot(element)] { c } else { nil }
    }

    @Test("the flag is written on the chord, and on nothing else in it")
    func writesFlag() throws {
        var score = EditingFixtures.twoBeamedEighths()
        _ = try SetStemVisible(at: Self.slot(1), visible: false).apply(to: &score)
        let lead = try #require(Self.chord(score, 1))
        #expect(!lead.stemVisible)
        #expect(lead.visible && lead.beamVisible && lead.notes[0].visible)
        #expect(SetStemVisible.current(at: Self.slot(1), in: score) == false)
        #expect(SetStemVisible.current(at: Self.slot(2), in: score) == true)
    }

    @Test("undo restores the flag the chord had")
    func inverseRestores() throws {
        var score = EditingFixtures.twoBeamedEighths()
        let before = score
        let inverse = try SetStemVisible(at: Self.slot(1), visible: false).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("true shows a hidden stem again")
    func shows() throws {
        var score = EditingFixtures.twoBeamedEighths()
        _ = try SetStemVisible(at: Self.slot(2), visible: false).apply(to: &score)
        _ = try SetStemVisible(at: Self.slot(2), visible: true).apply(to: &score)
        #expect(score == EditingFixtures.twoBeamedEighths())
    }

    @Test("only the addressed chord changes")
    func leavesSiblingsAlone() throws {
        var score = EditingFixtures.twoBeamedEighths()
        _ = try SetStemVisible(at: Self.slot(2), visible: false).apply(to: &score)
        #expect(Self.chord(score, 1)?.stemVisible == true)
        #expect(Self.chord(score, 2)?.stemVisible == false)
    }

    @Test("a rest, an untimed element and a missing slot are refused")
    func refusals() {
        var score = EditingFixtures.twoBeamedEighths()
        let before = score
        let rest = #expect(throws: SheetMusicError.self) {
            _ = try SetStemVisible(at: Self.slot(3), visible: false).apply(to: &score)
        }
        #expect(Self.reason(of: rest) == .wrongElementKind(at: Self.slot(3), expected: .chord))
        let meter = #expect(throws: SheetMusicError.self) {
            _ = try SetStemVisible(at: Self.slot(0), visible: false).apply(to: &score)
        }
        #expect(Self.reason(of: meter) == .wrongElementKind(at: Self.slot(0), expected: .chord))
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetStemVisible(at: Self.slot(9), visible: false).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(9)))
        #expect(score == before)
        #expect(SetStemVisible.current(at: Self.slot(3), in: score) == nil)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
