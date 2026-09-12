@testable import SheetMusicCore
import Testing

@Suite("RangeCopyGeometry")
struct RangeCopyGeometryTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    @Test("measure starts accumulate the staff's own measure lengths")
    func measureStarts() {
        let geometry = RangeCopyGeometry(staff: Self.flute, in: EditingFixtures.parityFixture())
        #expect(geometry.measureStarts == [0, 1920, 3840, 5760])
        #expect(geometry.totalTicks == 7680)
        #expect(geometry.measureLength(2) == 1920)
    }

    @Test("a position converts to an absolute tick and back")
    func roundTrip() {
        let geometry = RangeCopyGeometry(staff: Self.flute, in: EditingFixtures.parityFixture())
        let position = ScoreTickPosition(measure: 2, tick: 960)
        #expect(geometry.absolute(position) == 4800)
        #expect(geometry.position(atAbsolute: 4800) == position)
    }

    @Test("an absolute tick past the last bar has no position")
    func pastTheEnd() {
        let geometry = RangeCopyGeometry(staff: Self.flute, in: EditingFixtures.parityFixture())
        #expect(geometry.position(atAbsolute: 7680) == nil)
        #expect(geometry.position(atAbsolute: 9000) == nil)
    }

    @Test("a position in a measure the staff does not have has no absolute tick")
    func absoluteOfMissingMeasure() {
        let geometry = RangeCopyGeometry(staff: Self.flute, in: EditingFixtures.parityFixture())
        // The staff has four bars, so measure 4 is one past the end — and `totalTicks` (7680) is not its answer.
        #expect(geometry.absolute(ScoreTickPosition(measure: 4, tick: 0)) == nil)
    }
}
