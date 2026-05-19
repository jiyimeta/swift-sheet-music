import CoreGraphics
@testable import SheetMusicLayout
import Testing

@Suite("StemGeometry")
struct StemGeometryTests {
    @Test func emptyNoteOriginsYieldsNil() {
        let result = StemGeometry.compute(
            noteOrigins: [],
            direction: .up,
            beamY: nil,
            defaultStemLength: 28,
            sp: 5,
        )
        #expect(result == nil)
    }

    @Test func unbeamedUpStemAttachesRightOfRightmostNote() {
        // Two notes stacked vertically: stem goes up from the bottom one
        // and extends past the top by `defaultStemLength`.
        let result = try? #require(StemGeometry.compute(
            noteOrigins: [CGPoint(x: 10, y: 30), CGPoint(x: 10, y: 50)],
            direction: .up,
            beamY: nil,
            defaultStemLength: 28,
            sp: 5,
        ))
        #expect(result?.xStem == 10 + 5 * 0.59)
        #expect(result?.startY == CGFloat(2))
        #expect(result?.endY == CGFloat(50))
    }

    @Test func unbeamedDownStemAttachesLeftOfLeftmostNote() {
        let result = try? #require(StemGeometry.compute(
            noteOrigins: [CGPoint(x: 10, y: 30), CGPoint(x: 10, y: 50)],
            direction: .down,
            beamY: nil,
            defaultStemLength: 28,
            sp: 5,
        ))
        #expect(result?.xStem == 10 - 5 * 0.59)
        #expect(result?.startY == CGFloat(30))
        #expect(result?.endY == CGFloat(78))
    }

    @Test func beamYReplacesNaturalTipOnBeamSide() {
        // Up stem: beamY replaces the (yTop - stemLength) tip.
        let up = StemGeometry.compute(
            noteOrigins: [CGPoint(x: 0, y: 100)],
            direction: .up,
            beamY: 10,
            defaultStemLength: 28,
            sp: 5,
        )
        #expect(up?.startY == 10)
        #expect(up?.endY == 100)

        // Down stem: beamY replaces the (yBot + stemLength) tip.
        let down = StemGeometry.compute(
            noteOrigins: [CGPoint(x: 0, y: 100)],
            direction: .down,
            beamY: 140,
            defaultStemLength: 28,
            sp: 5,
        )
        #expect(down?.startY == 100)
        #expect(down?.endY == 140)
    }
}
