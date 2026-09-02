@testable import SheetMusicCore
import Testing

@Suite("SetLayoutBreak")
struct SetLayoutBreakTests {
    private static let m2 = MeasureRef(measureIndex: 2)

    @Test("sets exactly the addressed flag on the canonical staff", arguments: LayoutBreakKind.allCases)
    func setsOneFlag(kind: LayoutBreakKind) throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetLayoutBreak(at: Self.m2, kind: kind, enabled: true).apply(to: &score)
        let m = score.parts[0].staves[0].measures[2]
        #expect(m.lineBreak == (kind == .line))
        #expect(m.pageBreak == (kind == .page))
        #expect(m.sectionBreak == (kind == .section))
        #expect(!score.parts[1].staves[0].measures[2].lineBreak)
    }

    @Test("undo restores, and disabling clears")
    func undoAndClear() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try SetLayoutBreak(at: Self.m2, kind: .page, enabled: true).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
        _ = try SetLayoutBreak(at: Self.m2, kind: .page, enabled: true).apply(to: &score)
        _ = try SetLayoutBreak(at: Self.m2, kind: .page, enabled: false).apply(to: &score)
        #expect(score == before)
    }

    @Test("an out-of-range measure is refused")
    func refusesOutOfRange() {
        var score = EditingFixtures.parityFixture()
        #expect(throws: SheetMusicError.self) {
            _ = try SetLayoutBreak(at: MeasureRef(measureIndex: -1), kind: .line, enabled: true).apply(to: &score)
        }
    }
}
