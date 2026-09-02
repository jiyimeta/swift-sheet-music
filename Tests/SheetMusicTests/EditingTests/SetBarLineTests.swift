@testable import SheetMusicCore
import Testing

@Suite("SetBarLine")
struct SetBarLineTests {
    private static let m1 = MeasureRef(measureIndex: 1)

    private static func trailingBar(_ score: Score, staff: StaffAddress, measure: Int) -> BarLine? {
        let elements = score.parts[staff.partIndex].staves[staff.staffIndexInPart].measures[measure].voices[0].elements
        for element in elements.reversed() {
            if case let .barLine(bar) = element { return bar }
        }
        return nil
    }

    @Test("writes a trailing barline on every staff")
    func writesOnEveryStaff() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetBarLine(at: Self.m1, style: .double).apply(to: &score)
        let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        #expect(Self.trailingBar(score, staff: flute, measure: 1)?.subtype == "double")
        #expect(Self.trailingBar(score, staff: cello, measure: 1)?.subtype == "double")
        #expect(score.parts[0].staves[0].measures[1].voices[0].elements.count == 5)
    }

    @Test("replaces an existing trailing barline in place and undo restores")
    func replacesInPlace() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetBarLine(at: Self.m1, style: .double).apply(to: &score)
        let before = score
        let inverse = try SetBarLine(at: Self.m1, style: .end).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[1].voices[0].elements.count == 5)
        let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        #expect(Self.trailingBar(score, staff: flute, measure: 1)?.subtype == "end")
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("normal removes the explicit barline")
    func normalRemoves() throws {
        var score = EditingFixtures.parityFixture()
        let pristine = score
        _ = try SetBarLine(at: Self.m1, style: .double).apply(to: &score)
        _ = try SetBarLine(at: Self.m1, style: .normal).apply(to: &score)
        #expect(score == pristine)
    }

    @Test("a mid-measure barline is left alone")
    func midMeasureUntouched() throws {
        var score = EditingFixtures.parityFixture()
        score.parts[0].staves[0].measures[0].voices[0].elements.insert(.barLine(BarLine(subtype: "dashed")), at: 3)
        _ = try SetBarLine(at: MeasureRef(measureIndex: 0), style: .double).apply(to: &score)
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        guard case let .barLine(mid) = elements[3], case let .barLine(trailing) = elements[6] else {
            Issue.record("expected barlines at 3 and 6"); return
        }
        #expect(mid.subtype == "dashed")
        #expect(trailing.subtype == "double")
    }

    @Test("an out-of-range measure is refused")
    func refusesOutOfRange() {
        var score = EditingFixtures.parityFixture()
        #expect(throws: SheetMusicError.self) {
            _ = try SetBarLine(at: MeasureRef(measureIndex: 9), style: .double).apply(to: &score)
        }
    }
}
