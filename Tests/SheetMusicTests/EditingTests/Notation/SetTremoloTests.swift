@testable import SheetMusicCore
import Testing

/// `SetTremolo` — including the adjacency rule `.between` depends on (spec row 52).
@Suite("SetTremolo")
struct SetTremoloTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func tremolo(_ score: Score, _ id: VoiceElementID) -> Tremolo? {
        if case let .chord(chord)? = score[id] { chord.tremolo } else { nil }
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    @Test("a single-chord tremolo is written with its stroke style")
    func writes() throws {
        var score = EditingFixtures.parityFixture()
        let value = Tremolo(subtype: .r32, span: .single, strokeStyle: .traditional)
        _ = try SetTremolo(at: Self.slot(0, 1), tremolo: value).apply(to: &score)
        #expect(Self.tremolo(score, Self.slot(0, 1)) == value)
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try SetTremolo(at: Self.slot(0, 1), tremolo: Tremolo(subtype: .r8)).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("nil clears")
    func clears() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.slot(0, 1)
        _ = try SetTremolo(at: target, tremolo: Tremolo(subtype: .r16)).apply(to: &score)
        _ = try SetTremolo(at: target, tremolo: nil).apply(to: &score)
        #expect(Self.tremolo(score, target) == nil)
    }

    @Test("a .between tremolo is allowed when the next timed element is a chord")
    func betweenWithAFollower() throws {
        var score = EditingFixtures.parityFixture()
        let value = Tremolo(subtype: .r16, span: .between)
        _ = try SetTremolo(at: Self.slot(0, 1), tremolo: value).apply(to: &score)
        #expect(Self.tremolo(score, Self.slot(0, 1)) == value)
        // The follower is untouched: this model stores the pair one-sidedly.
        #expect(Self.tremolo(score, Self.slot(0, 2)) == nil)
    }

    @Test("a .between tremolo is refused over a rest and at the end of a bar")
    func betweenRefusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let overRest = #expect(throws: SheetMusicError.self) {
            // m0 element 2 is D4; the next timed element is a REST.
            _ = try SetTremolo(at: Self.slot(0, 2), tremolo: Tremolo(subtype: .r8, span: .between))
                .apply(to: &score)
        }
        #expect(Self.reason(of: overRest) == .noNextChord(at: Self.slot(0, 2)))
        let atBarEnd = #expect(throws: SheetMusicError.self) {
            // m2 is [E4 h, E4 h]; the tail has no in-bar follower.
            _ = try SetTremolo(at: Self.slot(2, 1), tremolo: Tremolo(subtype: .r8, span: .between))
                .apply(to: &score)
        }
        #expect(Self.reason(of: atBarEnd) == .noNextChord(at: Self.slot(2, 1)))
        #expect(score == before)
    }

    @Test("the siblings are untouched, and a rest / non-chord / missing target is refused")
    func siblingsAndRefusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let onRest = #expect(throws: SheetMusicError.self) {
            _ = try SetTremolo(at: Self.slot(0, 3), tremolo: Tremolo(subtype: .r8)).apply(to: &score)
        }
        #expect(Self.reason(of: onRest) == .wrongElementKind(at: Self.slot(0, 3), expected: .chord))
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetTremolo(at: Self.slot(0, 9), tremolo: nil).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(0, 9)))
        #expect(score == before)
        var written = EditingFixtures.parityFixture()
        _ = try? SetTremolo(at: Self.slot(0, 1), tremolo: Tremolo(subtype: .r8)).apply(to: &written)
        #expect(written.parts[1] == before.parts[1])
        #expect(written.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
    }
}
