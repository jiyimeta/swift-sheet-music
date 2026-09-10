@testable import SheetMusicCore
import Testing

@Suite("RemoveJump / RemoveMarker")
struct NavigationRemovalTests {
    private static let segno = Marker(kind: .segno, label: "segno", text: "Segno")
    private static let coda = Marker(kind: .coda, label: "coda", text: "Coda")
    private static let dalSegno = Jump(jumpTo: "segno", playUntil: "end", text: "D.S.")
    private static let daCapo = Jump(jumpTo: "start", playUntil: "end", text: "D.C.")

    private static func fixture() -> Score {
        var bar = Measure(voices: [Voice(elements: [.rest(duration: .whole)])])
        bar.markers = [segno, coda]
        bar.jumps = [dalSegno, daCapo]
        bar.startRepeat = true
        let staff = Staff(measures: [bar])
        return ScoreEditor(score: Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"), staves: [staff, staff],
        )])).score
    }

    @Test(
        "removes only the addressed staff's second entry and restores its full list",
        arguments: [false, true],
        [0, 1],
    )
    func singleStaff(_ marker: Bool, _ staffIndex: Int) throws {
        var score = Self.fixture()
        let before = score
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: staffIndex)
        let command: any EditCommand = marker
            ? RemoveMarker(staff: staff, measureIndex: 0, index: 1)
            : RemoveJump(staff: staff, measureIndex: 0, index: 1)
        #expect(command.affectedLocation == VoiceElementID(
            staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        ))
        let inverse = try command.apply(to: &score)
        var expected = before
        expected.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: staffIndex) { staff in
                if marker {
                    staff.measures[0].markers = [Self.segno]
                } else {
                    staff.measures[0].jumps = [Self.dalSegno]
                }
            }
        }
        #expect(score == expected)
        #expect(score.parts[0].staves[1 - staffIndex] == before.parts[0].staves[1 - staffIndex])
        #expect(score.parts[0].staves[staffIndex].measures[0].startRepeat)
        #expect(score.stableFingerprint != before.stableFingerprint)
        let redo = try inverse.apply(to: &score)
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
        _ = try redo.apply(to: &score)
        #expect(score == expected)
        #expect(score.stableFingerprint == expected.stableFingerprint)
    }

    @Test("invalid list indices, staff and measure are refused without a write", arguments: [false, true])
    func refusals(_ marker: Bool) {
        let cases: [(Int, Int, Int)] = [(1, 0, -1), (1, 0, 2), (2, 0, 0), (1, 1, 0), (1, -1, 0)]
        for (staffIndex, measureIndex, index) in cases {
            var score = Self.fixture()
            let before = score
            let staff = StaffAddress(partIndex: 0, staffIndexInPart: staffIndex)
            let command: any EditCommand = marker
                ? RemoveMarker(staff: staff, measureIndex: measureIndex, index: index)
                : RemoveJump(staff: staff, measureIndex: measureIndex, index: index)
            let error = #expect(throws: SheetMusicError.self) { _ = try command.apply(to: &score) }
            guard case let .invalidEdit(refusal)? = error else { Issue.record("expected refusal"); continue }
            #expect(refusal.reason == .targetNotFound(VoiceElementID(
                staff: staff, measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
            )))
            #expect(refusal.operation == (marker ? "RemoveMarker" : "RemoveJump"))
            #expect(score == before)
            #expect(score.stableFingerprint == before.stableFingerprint)
        }
    }
}

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
        var score = ScoreEditor(score: EditingFixtures.parityFixture()).score
        _ = try SetJumps(at: Self.m3, jumps: [Self.dalSegno]).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[3].jumps == [Self.dalSegno])
        #expect(score.parts[1].staves[0].measures[3].jumps.isEmpty)
    }

    @Test("markers are written on the canonical staff only, and a second write replaces the list")
    func writesMarkers() throws {
        var score = ScoreEditor(score: EditingFixtures.parityFixture()).score
        _ = try SetMarkers(at: Self.m3, markers: [Self.segno]).apply(to: &score)
        _ = try SetMarkers(at: Self.m3, markers: [Self.segno, Self.fine]).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[3].markers == [Self.segno, Self.fine])
        #expect(score.parts[1].staves[0].measures[3].markers.isEmpty)
    }

    @Test("an empty list clears, and every inverse restores the prior list")
    func clearAndUndo() throws {
        var score = ScoreEditor(score: EditingFixtures.parityFixture()).score
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
        var score = ScoreEditor(score: EditingFixtures.parityFixture()).score
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
        var score = ScoreEditor(score: EditingFixtures.parityFixture()).score
        #expect(throws: SheetMusicError.self) {
            _ = try SetJumps(at: MeasureRef(measureIndex: 4), jumps: [Self.daCapo]).apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            _ = try SetMarkers(at: MeasureRef(measureIndex: -1), markers: [Self.fine]).apply(to: &score)
        }
    }
}
