@testable import SheetMusicCore
import Testing

/// `SetJumps` and `SetMarkers`: list replacement on the canonical staff's measure, with the pre-image as inverse.
@Suite("SetJumps / SetMarkers")
struct JumpMarkerCommandTests {
    private static let m3 = MeasureRef(measureIndex: 3)
    private static let dalSegno = Jump(jumpTo: "segno", playUntil: "coda", continueAt: "codab", text: "D.S. al Coda")
    private static let daCapo = Jump(jumpTo: "start", playUntil: "end", text: "D.C.")
    private static let segno = Marker(kind: .segno, label: "segno", text: "<sym>segno</sym>")
    private static let fine = Marker(kind: .fine, label: "fine", text: "Fine")

    @Test("jumps are written on the canonical staff only")
    func writesJumps() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetJumps(at: Self.m3, jumps: [Self.dalSegno]).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[3].jumps == [Self.dalSegno])
        #expect(score.parts[1].staves[0].measures[3].jumps.isEmpty)
    }

    @Test("markers are written on the canonical staff only, and a second write replaces the list")
    func writesMarkers() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetMarkers(at: Self.m3, markers: [Self.segno]).apply(to: &score)
        _ = try SetMarkers(at: Self.m3, markers: [Self.segno, Self.fine]).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[3].markers == [Self.segno, Self.fine])
        #expect(score.parts[1].staves[0].measures[3].markers.isEmpty)
    }

    @Test("an empty list clears, and every inverse restores the prior list")
    func clearAndUndo() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let first = try SetJumps(at: Self.m3, jumps: [Self.daCapo]).apply(to: &score)
        let second = try SetJumps(at: Self.m3, jumps: [Self.dalSegno, Self.daCapo]).apply(to: &score)
        let cleared = try SetJumps(at: Self.m3, jumps: []).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[3].jumps.isEmpty)
        _ = try cleared.apply(to: &score)
        #expect(score.parts[0].staves[0].measures[3].jumps == [Self.dalSegno, Self.daCapo])
        _ = try second.apply(to: &score)
        #expect(score.parts[0].staves[0].measures[3].jumps == [Self.daCapo])
        _ = try first.apply(to: &score)
        #expect(score == before)
    }

    @Test("markers and jumps on the same bar do not disturb each other, nor the bar's other flags")
    func siblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetRepeatBarLines(at: Self.m3, startRepeat: true, endRepeatCount: 2).apply(to: &score)
        _ = try SetMarkers(at: Self.m3, markers: [Self.fine]).apply(to: &score)
        _ = try SetJumps(at: Self.m3, jumps: [Self.daCapo]).apply(to: &score)
        _ = try SetMarkers(at: Self.m3, markers: []).apply(to: &score)
        let bar = score.parts[0].staves[0].measures[3]
        #expect(bar.jumps == [Self.daCapo])
        #expect(bar.markers.isEmpty)
        #expect(bar.startRepeat)
        #expect(bar.endRepeatCount == 2)
        #expect(score.parts[0].staves[0].measures[2] == EditingFixtures.parityFixture().parts[0].staves[0].measures[2])
    }

    @Test("an out-of-range measure is refused by both")
    func refusesOutOfRange() {
        var score = EditingFixtures.parityFixture()
        #expect(throws: SheetMusicError.self) {
            _ = try SetJumps(at: MeasureRef(measureIndex: 4), jumps: [Self.daCapo]).apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            _ = try SetMarkers(at: MeasureRef(measureIndex: -1), markers: [Self.fine]).apply(to: &score)
        }
    }
}
