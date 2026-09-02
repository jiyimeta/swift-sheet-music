@testable import SheetMusicCore
import Testing

@Suite("SetRepeatBarLines")
struct SetRepeatBarLinesTests {
    private static let m1 = MeasureRef(measureIndex: 1)

    @Test("writes both flags on the canonical staff only")
    func writesFlags() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetRepeatBarLines(at: Self.m1, startRepeat: true, endRepeatCount: 3).apply(to: &score)
        let canonical = score.parts[0].staves[0].measures[1]
        #expect(canonical.startRepeat)
        #expect(canonical.endRepeatCount == 3)
        #expect(!score.parts[1].staves[0].measures[1].startRepeat)
    }

    @Test("undo restores the prior flags")
    func undoRestores() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try SetRepeatBarLines(at: Self.m1, startRepeat: true, endRepeatCount: 2).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a play count below two is refused")
    func refusesLowCount() {
        var score = EditingFixtures.parityFixture()
        #expect(throws: SheetMusicError.self) {
            _ = try SetRepeatBarLines(at: Self.m1, startRepeat: false, endRepeatCount: 1).apply(to: &score)
        }
    }

    @Test("an out-of-range measure is refused")
    func refusesOutOfRange() {
        var score = EditingFixtures.parityFixture()
        #expect(throws: SheetMusicError.self) {
            let outOfRange = MeasureRef(measureIndex: 4)
            _ = try SetRepeatBarLines(at: outOfRange, startRepeat: true, endRepeatCount: nil).apply(to: &score)
        }
    }
}
