#if canImport(CoreGraphics)
    import CoreGraphics
#endif
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

    // MARK: - The crescent

    /// The crescent as the Apple `TieRenderer` and `ScoreLayerBuilder.drawTieArc` built it inline before
    /// `TieArcGeometry.crescent` (2026-11-20): the reference the shared shape must reproduce point for point, so the
    /// Apple renderer draws the same pixels.
    private func appleCrescent(from: CGPoint, to: CGPoint, above: Bool, sp: CGFloat) -> TieArcGeometry.Crescent {
        let points = TieArcGeometry.controlPoints(
            from: from, to: to, above: above,
            heightSp: TieArcGeometry.shoulderHeightSp(tieLengthSp: abs(to.x - from.x) / sp),
            sp: sp,
        )
        let vertSign: CGFloat = above ? -1 : 1
        let midThickness = sp * 0.15
        let thickDy = midThickness * vertSign * -1
        return TieArcGeometry.Crescent(
            start: points.p0, end: points.p3,
            outer1: CGPoint(x: points.p1.x, y: points.p1.y - thickDy),
            outer2: CGPoint(x: points.p2.x, y: points.p2.y - thickDy),
            inner1: CGPoint(x: points.p2.x, y: points.p2.y + thickDy),
            inner2: CGPoint(x: points.p1.x, y: points.p1.y + thickDy),
        )
    }

    @Test func crescentIsTheShapeTheAppleRendererDrew() {
        for above in [true, false] {
            for (from, to, sp) in [
                (CGPoint(x: 10, y: 40), CGPoint(x: 60, y: 40), CGFloat(5)),
                (CGPoint(x: 3.7, y: 22.1), CGPoint(x: 141.3, y: 19.8), CGFloat(4.96)),
                (CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 1), CGFloat(7)),
            ] {
                #expect(
                    TieArcGeometry.crescent(from: from, to: to, above: above, sp: sp)
                        == appleCrescent(from: from, to: to, above: above, sp: sp),
                    "\(from) → \(to), sp \(sp), above \(above)",
                )
            }
        }
    }

    /// The point at t = ½ of a cubic: (p0 + 3·c1 + 3·c2 + p3) / 8.
    private func midpoint(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint) -> CGPoint {
        CGPoint(x: (p0.x + 3 * c1.x + 3 * c2.x + p3.x) / 8, y: (p0.y + 3 * c1.y + 3 * c2.y + p3.y) / 8)
    }

    @Test func crescentTapersToTheTipsAndSwellsToAboutMuseScoresMidWidth() {
        let sp: CGFloat = 5
        for above in [true, false] {
            let crescent = TieArcGeometry.crescent(
                from: CGPoint(x: 0, y: 50), to: CGPoint(x: 80, y: 50), above: above, sp: sp,
            )
            let outer = midpoint(crescent.start, crescent.outer1, crescent.outer2, crescent.end)
            let inner = midpoint(crescent.end, crescent.inner1, crescent.inner2, crescent.start)
            // 0.75 × 2 × 0.15 sp at the shoulder; MuseScore's tieMidWidth is 0.21 sp.
            #expect(abs(abs(outer.y - inner.y) - 0.225 * sp) < 1e-9)
            // The outer curve is the one further from the notes: higher above them, lower below them.
            #expect(above ? outer.y < inner.y : outer.y > inner.y)
        }
    }
}
