import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// CALayer companions to `TieRenderer` / `TremoloRenderer` — same
/// geometry, rendered as `CAShapeLayer`s instead of GraphicsContext
/// paths.
@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    static func drawTieArc(
        from: CGPoint, to: CGPoint, above: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let points = TieArcGeometry.controlPoints(
            from: from, to: to, above: above,
            heightSp: TieArcGeometry.shoulderHeightSp(tieLengthSp: abs(to.x - from.x) / metrics.sp),
            sp: metrics.sp,
        )
        let startPt = points.p0
        let endPt = points.p3
        let ctrl1 = points.p1
        let ctrl2 = points.p2
        let vertSign: CGFloat = above ? -1 : 1
        let midThickness = metrics.sp * 0.15
        let thickDy = midThickness * vertSign * -1

        let path = CGMutablePath()
        path.move(to: startPt)
        path.addCurve(
            to: endPt,
            control1: CGPoint(x: ctrl1.x, y: ctrl1.y - thickDy),
            control2: CGPoint(x: ctrl2.x, y: ctrl2.y - thickDy),
        )
        path.addCurve(
            to: startPt,
            control1: CGPoint(x: ctrl2.x, y: ctrl2.y + thickDy),
            control2: CGPoint(x: ctrl1.x, y: ctrl1.y + thickDy),
        )
        path.closeSubpath()
        parent.addSublayer(fillLayer(
            path: path, height: height,
        ))
    }

    // MARK: - Tremolo bars

    /// CALayer companion to `TremoloRenderer.draw`. Same geometry,
    /// rendered as stroked `CAShapeLayer`s instead of GraphicsContext
    /// paths.
    static func drawTremoloBars(
        anchor: TremoloAnchor, barCount: Int,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let bars = TremoloGeometry.bars(
            anchor: anchor, barCount: barCount, sp: metrics.sp,
        )
        guard !bars.isEmpty else { return }
        let thickness = TremoloGeometry.barThickness(sp: metrics.sp)
        for bar in bars {
            let path = CGMutablePath()
            path.move(to: bar.from)
            path.addLine(to: bar.to)
            parent.addSublayer(strokeLayer(
                path: path, height: height, lineWidth: thickness,
            ))
        }
    }
}
