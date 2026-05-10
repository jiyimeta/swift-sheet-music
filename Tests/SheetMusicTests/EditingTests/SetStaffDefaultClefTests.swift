@testable import SheetMusicCore
import Testing

@Suite("SetStaffDefaultClef")
struct SetStaffDefaultClefTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private func twoStaffScore(
        firstDefault: String? = "G",
        secondDefault: String? = "F"
    ) -> Score {
        let staff0 = Staff(
            defaultClefType: firstDefault,
            measures: [Measure(voices: [Voice(elements: [])])]
        )
        let staff1 = Staff(
            defaultClefType: secondDefault,
            measures: [Measure(voices: [Voice(elements: [])])]
        )
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "x"),
            staves: [staff0, staff1]
        )
        return Score(division: 480, parts: [part])
    }

    @Test("apply then inverse round-trips")
    func applyAndInverseRoundTrip() throws {
        var score = twoStaffScore()
        let cmd = SetStaffDefaultClef(staff: Self.staff0, newRawType: "F")
        let inverse = try cmd.apply(to: &score)
        #expect(score[Self.staff0]?.defaultClefType == "F")

        var post = score
        _ = try inverse.apply(to: &post)
        #expect(post[Self.staff0]?.defaultClefType == "G")
    }

    @Test("nil clears and inverse restores")
    func nilClearsAndRestores() throws {
        var score = twoStaffScore()
        let cmd = SetStaffDefaultClef(staff: Self.staff0, newRawType: nil)
        let inverse = try cmd.apply(to: &score)
        #expect(score[Self.staff0]?.defaultClefType == nil)

        var post = score
        _ = try inverse.apply(to: &post)
        #expect(post[Self.staff0]?.defaultClefType == "G")
    }

    @Test("invalid staff throws")
    func invalidStaffThrows() throws {
        var score = twoStaffScore()
        let cmd = SetStaffDefaultClef(
            staff: StaffAddress(partIndex: 9, staffIndexInPart: 0),
            newRawType: "G"
        )
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
