import CoreGraphics
@testable import SheetMusicLayout
import Testing

@Suite("TieArcGeometry")
struct TieArcGeometryTests {
    @Test func endpointsClearNoteheadInk() {
        // `above: true` lifts the endpoints by -headClearance * sp.
        let pts = TieArcGeometry.controlPoints(
            from: CGPoint(x: 0, y: 100),
            to: CGPoint(x: 100, y: 100),
            above: true,
            heightSp: 1,
            sp: 5,
        )
        let clearance = TieArcGeometry.defaultHeadClearanceSp * 5
        #expect(pts.p0 == CGPoint(x: 0, y: 100 - clearance))
        #expect(pts.p3 == CGPoint(x: 100, y: 100 - clearance))
    }

    @Test func controlPointsSitAtTwentyAndEightyPercent() {
        let pts = TieArcGeometry.controlPoints(
            from: CGPoint(x: 0, y: 100),
            to: CGPoint(x: 100, y: 100),
            above: true,
            heightSp: 2,
            sp: 5,
        )
        // x at 20% / 80% of the span.
        #expect(pts.p1.x == 20)
        #expect(pts.p2.x == 80)
        // y: clearance (3) above baseline + shoulder (10) above = 13 above.
        let clearance = TieArcGeometry.defaultHeadClearanceSp * 5
        let shoulder = CGFloat(2 * 5)
        #expect(pts.p1.y == 100 - clearance - shoulder)
        #expect(pts.p2.y == 100 - clearance - shoulder)
    }

    @Test func belowFlipsShoulderSign() {
        let above = TieArcGeometry.controlPoints(
            from: .zero, to: CGPoint(x: 50, y: 0),
            above: true, heightSp: 1, sp: 5,
        )
        let below = TieArcGeometry.controlPoints(
            from: .zero, to: CGPoint(x: 50, y: 0),
            above: false, heightSp: 1, sp: 5,
        )
        #expect(above.p1.y == -below.p1.y)
        #expect(above.p2.y == -below.p2.y)
    }
}
