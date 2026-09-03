@testable import SheetMusicCore
import Testing

@Suite("SetElementVisible")
struct SetElementVisibleTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    /// `[ts, dynamic, C4, r, r, r]` — a chord wearing a dynamic, so both a timed and an untimed target exist.
    private static func dressedScore() -> Score {
        var score = EditingFixtures.chordAtIndex1()
        score.parts[0].staves[0].measures[0].voices[0].elements.insert(
            .dynamic(Dynamic(subtype: "p", velocity: 49)), at: 1,
        )
        return score
    }

    @Test("the flag is written on a chord, and on an untimed element")
    func writes() throws {
        var score = Self.dressedScore()
        _ = try SetElementVisible(at: Self.slot(2), visible: false).apply(to: &score)
        _ = try SetElementVisible(at: Self.slot(1), visible: false).apply(to: &score)
        guard case let .chord(chord)? = score[Self.slot(2)], case let .dynamic(dynamic)? = score[Self.slot(1)] else {
            Issue.record("expected a chord and a dynamic")
            return
        }
        #expect(!chord.visible)
        #expect(!dynamic.visible)
        #expect(chord.notes[0].visible) // the chord flag does not fan out to its notes
        #expect(SetElementVisible.current(at: Self.slot(2), in: score) == false)
        #expect(SetElementVisible.current(at: Self.slot(0), in: score) == true) // the meter, untouched
    }

    @Test("undo restores the flag the element had")
    func inverseRestores() throws {
        var score = Self.dressedScore()
        let before = score
        let hide = try SetElementVisible(at: Self.slot(2), visible: false).apply(to: &score)
        let show = try SetElementVisible(at: Self.slot(1), visible: false).apply(to: &score)
        _ = try show.apply(to: &score)
        _ = try hide.apply(to: &score)
        #expect(score == before)
    }

    @Test("true shows an element hidden earlier, keeping the rest of its state")
    func shows() throws {
        var score = Self.dressedScore()
        _ = try SetElementVisible(at: Self.slot(1), visible: false).apply(to: &score)
        _ = try SetElementVisible(at: Self.slot(1), visible: true).apply(to: &score)
        #expect(score[Self.slot(1)] == .dynamic(Dynamic(subtype: "p", velocity: 49)))
    }

    @Test("only the addressed element changes")
    func leavesSiblingsAlone() throws {
        var score = Self.dressedScore()
        let before = score
        _ = try SetElementVisible(at: Self.slot(2), visible: false).apply(to: &score)
        for index in [0, 1, 3, 4, 5] {
            #expect(score[Self.slot(index)] == before[Self.slot(index)])
        }
    }

    @Test("a measure repeat, a location shift and a missing slot are refused")
    func refusals() throws {
        var score = EditingFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures[0].voices[0].elements[1] =
            .locationShift(delta: Fraction(numerator: 1, denominator: 4))
        let before = score
        let shift = #expect(throws: SheetMusicError.self) {
            _ = try SetElementVisible(at: Self.slot(1), visible: false).apply(to: &score)
        }
        #expect(Self.reason(of: shift) == .wrongElementKind(at: Self.slot(1), expected: .engravable))
        // A measure-repeat sign, written by the group-1 command into an empty bar (spec row 33).
        var repeated = EditingFixtures.fullMeasureRest()
        _ = try SetMeasureRepeat(at: MeasureRef(measureIndex: 0), staff: Self.staff0, numMeasures: 1)
            .apply(to: &repeated)
        let signIndex = try #require(repeated.parts[0].staves[0].measures[0].voices[0].elements.firstIndex {
            if case .measureRepeat = $0 { true } else { false }
        })
        let sign = #expect(throws: SheetMusicError.self) {
            _ = try SetElementVisible(at: Self.slot(signIndex), visible: false).apply(to: &repeated)
        }
        #expect(Self.reason(of: sign) == .wrongElementKind(at: Self.slot(signIndex), expected: .engravable))
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetElementVisible(at: Self.slot(9), visible: false).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(9)))
        #expect(score == before)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
