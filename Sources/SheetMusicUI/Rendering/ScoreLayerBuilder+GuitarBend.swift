import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    // MARK: - Guitar bend

    /// CALayer counterpart of `GuitarBendRenderer` — see that file for
    /// the C++ provenance of both shapes and of the pen.
    ///
    /// `CAShapeLayer` already defaults to `.butt` / `.miter`, but the
    /// two are set explicitly so this stays pinned to
    /// `TDraw::draw(const GuitarBendSegment*)` (`tdraw.cpp:1637-1638`)
    /// rather than to a framework default that could change.
    static func drawGuitarBend(
        from: CGPoint,
        vertex: CGPoint,
        to: CGPoint,
        slight: Bool,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        let path = CGMutablePath()
        path.move(to: from)
        if slight {
            path.addCurve(to: to, control1: from, control2: vertex)
        } else {
            path.addLine(to: vertex)
            path.addLine(to: to)
        }
        let layer = strokeLayer(
            path: path, height: height,
            lineWidth: metrics.sp * GuitarBendGeometry.lineThicknessSp,
        )
        layer.lineCap = .butt
        layer.lineJoin = .miter
        parent.addSublayer(layer)
    }
}
