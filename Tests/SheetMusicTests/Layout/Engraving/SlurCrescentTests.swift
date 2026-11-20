#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicBridgeCore
@testable import SheetMusicLayout
import Testing

/// A slur filled as MuseScore fills it (`SpannerGeometry.slurCrescent`): `slurEndWidthSp` at the tips, MuseScore's
/// `0.75 × 2 × midThickness + endWidth` at the shoulder, opened perpendicular to the chord (folino owner's call,
/// 2026-11-21).
@Suite("Slur crescent")
struct SlurCrescentTests {
    private let sp: CGFloat = 5

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// The point at t = ½ of a cubic.
    private func midpoint(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint) -> CGPoint {
        CGPoint(x: (p0.x + 3 * c1.x + 3 * c2.x + p3.x) / 8, y: (p0.y + 3 * c1.y + 3 * c2.y + p3.y) / 8)
    }

    @Test func `the mid thickness is MuseScore's, thinner for a slur under 4 sp`() {
        // midWidth − endWidth beyond 4 sp; 0.15 − endWidth at minTieLength (1 sp); a straight line between.
        #expect(abs(SpannerGeometry.slurMidThicknessSp(lengthSp: 12) - 0.16) < 1e-12)
        #expect(abs(SpannerGeometry.slurMidThicknessSp(lengthSp: 4) - 0.16) < 1e-12)
        #expect(abs(SpannerGeometry.slurMidThicknessSp(lengthSp: 1) - 0.10) < 1e-12)
        #expect(abs(SpannerGeometry.slurMidThicknessSp(lengthSp: 2.5) - 0.13) < 1e-12)
    }

    @Test func `the tips are the end width wide and the shoulder is MuseScore's thickness`() {
        let crescent = SpannerGeometry.slurCrescent(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 40, y: 50), sp: sp)
        #expect(abs(distance(crescent.outerStart, crescent.innerEnd) - 0.05 * sp) < 1e-9)
        #expect(abs(distance(crescent.outerEnd, crescent.innerStart) - 0.05 * sp) < 1e-9)
        let outer = midpoint(crescent.outerStart, crescent.outer1, crescent.outer2, crescent.outerEnd)
        let inner = midpoint(crescent.innerStart, crescent.inner1, crescent.inner2, crescent.innerEnd)
        // 8 sp long: 0.75 × 2 × 0.16 + 0.05 = 0.29 sp, as MuseScore fills and outlines it.
        #expect(abs(distance(outer, inner) - 0.29 * sp) < 1e-9)
        // The slur bulges up (smaller y), and the outer curve is the one on the shoulder's side.
        #expect(outer.y < inner.y)
    }

    @Test func `a sloped slur opens perpendicular to its chord`() {
        let from = CGPoint(x: 10, y: 60)
        let to = CGPoint(x: 70, y: 40)
        let crescent = SpannerGeometry.slurCrescent(from: from, to: to, sp: sp)
        let across = CGPoint(
            x: crescent.outerStart.x - crescent.innerEnd.x,
            y: crescent.outerStart.y - crescent.innerEnd.y,
        )
        #expect(abs(across.x * (to.x - from.x) + across.y * (to.y - from.y)) < 1e-9)
        // Centred on the slur's own tips.
        #expect(abs((crescent.outerStart.x + crescent.innerEnd.x) / 2 - from.x) < 1e-9)
        #expect(abs((crescent.outerEnd.y + crescent.innerStart.y) / 2 - to.y) < 1e-9)
    }

    @Test func `the draw program fills the crescent instead of stroking the curve`() {
        let crescent = SpannerGeometry.slurCrescent(from: CGPoint(x: 12, y: 40), to: CGPoint(x: 60, y: 44), sp: 4.96)
        var out: [DrawCommand] = []
        LayoutBridge.encodeSlurCrescent(crescent, into: &out)
        let scale = LayoutBridge.ptToMMScale
        func mm(_ point: CGPoint) -> (Double, Double) {
            (Double(point.x) * scale, Double(point.y) * scale)
        }
        let (osX, osY) = mm(crescent.outerStart)
        let (o1X, o1Y) = mm(crescent.outer1)
        let (o2X, o2Y) = mm(crescent.outer2)
        let (oeX, oeY) = mm(crescent.outerEnd)
        let (isX, isY) = mm(crescent.innerStart)
        let (i1X, i1Y) = mm(crescent.inner1)
        let (i2X, i2Y) = mm(crescent.inner2)
        let (ieX, ieY) = mm(crescent.innerEnd)
        #expect(out == [
            .moveTo(x: osX, y: osY),
            .cubicTo(cx1: o1X, cy1: o1Y, cx2: o2X, cy2: o2Y, x: oeX, y: oeY),
            .lineTo(x: isX, y: isY),
            .cubicTo(cx1: i1X, cy1: i1Y, cx2: i2X, cy2: i2Y, x: ieX, y: ieY),
            .fillPath,
        ])
    }
}
