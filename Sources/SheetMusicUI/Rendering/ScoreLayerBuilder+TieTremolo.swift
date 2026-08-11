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
        let headClearance = metrics.sp * 0.6
        let vertSign: CGFloat = above ? -1 : 1
        let startPt = CGPoint(
            x: from.x,
            y: from.y + headClearance * vertSign,
        )
        let endPt = CGPoint(
            x: to.x,
            y: to.y + headClearance * vertSign,
        )

        let minShoulder = metrics.sp * 0.3
        let maxShoulder = metrics.sp * 2.0
        let tieLen = abs(endPt.x - startPt.x)
        let tieLenSp = max(tieLen / metrics.sp, 1.0)
        let shoulderH: CGFloat = {
            let raw = minShoulder
                + metrics.sp * 0.3 * sqrt(tieLenSp - 1)
            return min(max(raw, minShoulder), maxShoulder)
        }()
        let midThickness = metrics.sp * 0.15

        let dx = endPt.x - startPt.x
        let dy = endPt.y - startPt.y
        let ctrl1 = CGPoint(
            x: startPt.x + dx * 0.2,
            y: startPt.y + dy * 0.2 + shoulderH * vertSign,
        )
        let ctrl2 = CGPoint(
            x: startPt.x + dx * 0.8,
            y: startPt.y + dy * 0.8 + shoulderH * vertSign,
        )
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
