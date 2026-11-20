#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicBridgeCore
import SheetMusicLayout
import Testing

/// The draw program's tie (`LayoutBridge.encodeTieArc`) is the crescent the Apple renderer fills
/// (`TieArcGeometry.crescent`), not one curve stroked at a constant width — what the Android, web and Windows renderers
/// drew as an even arc with blunt ends (folino owner's QA, 2026-11-20).
@Suite("Tie arc encoding")
struct TieArcEncodingTests {
    @Test func `a tie is two cubics sharing their ends, filled, with no stroke`() {
        for above in [true, false] {
            var out: [DrawCommand] = []
            LayoutBridge.encodeTieArc(fromX: 12, fromY: 40, toX: 70, toY: 41, above: above, sp: 4.96, into: &out)
            let crescent = TieArcGeometry.crescent(
                from: CGPoint(x: 12, y: 40), to: CGPoint(x: 70, y: 41), above: above, sp: 4.96,
            )
            let scale = LayoutBridge.ptToMMScale
            func mm(_ point: CGPoint) -> (Double, Double) {
                (Double(point.x) * scale, Double(point.y) * scale)
            }
            let (startX, startY) = mm(crescent.start)
            let (endX, endY) = mm(crescent.end)
            let (outer1X, outer1Y) = mm(crescent.outer1)
            let (outer2X, outer2Y) = mm(crescent.outer2)
            let (inner1X, inner1Y) = mm(crescent.inner1)
            let (inner2X, inner2Y) = mm(crescent.inner2)
            #expect(out == [
                .moveTo(x: startX, y: startY),
                .cubicTo(cx1: outer1X, cy1: outer1Y, cx2: outer2X, cy2: outer2Y, x: endX, y: endY),
                .cubicTo(cx1: inner1X, cy1: inner1Y, cx2: inner2X, cy2: inner2Y, x: startX, y: startY),
                .fillPath,
            ], "above \(above)")
        }
    }
}
