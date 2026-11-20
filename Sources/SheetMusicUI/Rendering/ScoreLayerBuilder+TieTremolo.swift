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
        let crescent = TieArcGeometry.crescent(from: from, to: to, above: above, sp: metrics.sp)
        let path = CGMutablePath()
        path.move(to: crescent.start)
        path.addCurve(to: crescent.end, control1: crescent.outer1, control2: crescent.outer2)
        path.addCurve(to: crescent.start, control1: crescent.inner1, control2: crescent.inner2)
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
