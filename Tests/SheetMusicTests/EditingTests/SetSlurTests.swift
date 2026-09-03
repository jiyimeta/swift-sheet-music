@testable import SheetMusicCore
import Testing

/// `SetSlur` — the one command with the chord-anchored storage form, and therefore the one whose write moves no
/// element index and whose fingerprint depends on Task 2.
@Suite("SetSlur")
struct SetSlurTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    @Test("writes a slur on the start chord pointing at the end chord's onset, moving no index")
    func writes() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetSlur(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)))
            .apply(to: &score)
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements.count == 5)
        guard case let .chord(head) = elements[1] else { Issue.record("expected the C4"); return }
        #expect(head.spanners.map(\.kind) == [.slur])
        #expect(head.spanners[0].rawType == "Slur")
        #expect(head.spanners[0].nextFractionsOffset == Fraction(numerator: 1, denominator: 4))
    }

    @Test("the fingerprint sees it — the group-1 amendment's requirement, end to end")
    func fingerprintMoves() throws {
        var score = EditingFixtures.parityFixture()
        let before = score.stableFingerprint
        _ = try SetSlur(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2))).apply(to: &score)
        #expect(score.stableFingerprint != before)
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try SetSlur(over: VoiceElementRange(start: Self.slot(2, 0), end: Self.slot(2, 1)))
            .apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("the other staff and the other bars are untouched")
    func siblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        _ = try SetSlur(over: VoiceElementRange(start: Self.slot(2, 0), end: Self.slot(2, 1))).apply(to: &score)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[0 ..< 2] == before.parts[0].staves[0].measures[0 ..< 2])
        #expect(score.parts[0].staves[0].measures[3] == before.parts[0].staves[0].measures[3])
    }

    @Test("a one-chord range, a second slur at the same chord and a missing target are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let lonely = #expect(throws: SheetMusicError.self) {
            _ = try SetSlur(over: VoiceElementRange(start: Self.slot(2, 0), end: Self.slot(2, 0)))
                .apply(to: &score)
        }
        #expect(Self.reason(of: lonely) == .noNextChord(at: Self.slot(2, 0)))
        #expect(throws: SheetMusicError.self) {
            _ = try SetSlur(over: VoiceElementRange(start: Self.slot(9, 0), end: Self.slot(9, 1)))
                .apply(to: &score)
        }
        #expect(score == before)
        _ = try? SetSlur(over: VoiceElementRange(start: Self.slot(2, 0), end: Self.slot(2, 1))).apply(to: &score)
        let twice = #expect(throws: SheetMusicError.self) {
            _ = try SetSlur(over: VoiceElementRange(start: Self.slot(2, 0), end: Self.slot(2, 1)))
                .apply(to: &score)
        }
        #expect(Self.reason(of: twice) == .duplicateSpanner(at: Self.slot(2, 0), kind: .slur))
    }
}
