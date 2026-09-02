@testable import SheetMusicCore
import Testing

@Suite("MeasureFlagsHoist")
struct MeasureFlagsHoistTests {
    /// Two single-staff parts, two measures; measure 1 of the canonical staff carries a line break and an end repeat.
    private static func twoParts() -> Score {
        var score = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        _ = try? AddPart(plan: .init(instrumentID: "cello", staves: [.init(clefType: "F")]), at: 1).apply(to: &score)
        score.parts[0].staves[0].measures[1].lineBreak = true
        score.parts[0].staves[0].measures[1].endRepeatCount = 2
        return score
    }

    @Test("removing part 0 carries its flags onto the new first staff")
    func removePartHoists() throws {
        var score = Self.twoParts()
        _ = try RemovePart(partIndex: 0).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[1].lineBreak)
        #expect(score.parts[0].staves[0].measures[1].endRepeatCount == 2)
    }

    @Test("undoing that removal restores the score byte-exact, stray flags on the demoted staff included")
    func removePartUndoIsExact() throws {
        var score = Self.twoParts()
        score.parts[1].staves[0].measures[0].pageBreak = true // a stray flag the invariant says is meaningless
        let before = score
        let inverse = try RemovePart(partIndex: 0).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("removing a part that is not first leaves the canonical staff alone")
    func removeOtherPartIsInert() throws {
        var score = Self.twoParts()
        _ = try RemovePart(partIndex: 1).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[1].lineBreak)
    }

    @Test("moving part 0 down moves the flags to the part that becomes first, and back on undo")
    func movePartHoists() throws {
        var score = Self.twoParts()
        let before = score
        let inverse = try MovePart(from: 0, to: 1).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[1].lineBreak)
        #expect(!score.parts[1].staves[0].measures[1].lineBreak)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("moving a part onto index 0 pulls the flags along the same way")
    func movePartOntoZero() throws {
        var score = Self.twoParts()
        let before = score
        let inverse = try MovePart(from: 1, to: 0).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[1].endRepeatCount == 2)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }
}
