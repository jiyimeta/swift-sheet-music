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
    // MARK: - Legacy bend

    /// CALayer counterpart of `LegacyBendRenderer` — see that file for
    /// the C++ provenance of the pen, the arrowheads and the label
    /// alignment. The paths themselves come from the renderer so the
    /// two back ends cannot drift apart geometrically.
    ///
    /// `CAShapeLayer` defaults to `.butt` / `.miter`, so the round cap
    /// and join of `TDraw::draw(const Bend*)` (`tdraw.cpp:951`) have to
    /// be set explicitly here.
    static func drawLegacyBend(
        shape: LegacyBendShape,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        let outline = LegacyBendRenderer.outlinePath(for: shape)
        if !outline.isEmpty {
            let layer = strokeLayer(
                path: outline, height: height,
                lineWidth: metrics.sp
                    * LegacyBendGeometry.lineThicknessSp,
            )
            layer.lineCap = .round
            layer.lineJoin = .round
            parent.addSublayer(layer)
        }

        let arrowWidth = metrics.sp * LegacyBendGeometry.arrowWidthSp
        for piece in shape.pieces {
            switch piece {
            case let .arrow(tip, up):
                parent.addSublayer(fillLayer(
                    path: LegacyBendRenderer.arrowPath(
                        tip: tip, up: up, arrowWidth: arrowWidth,
                    ),
                    height: height,
                ))
            case let .label(text, anchor):
                drawLegacyBendLabel(
                    text, anchor: anchor, metrics: metrics,
                    height: height, into: parent,
                )
            case .line, .curve:
                continue
            }
        }
    }

    /// Bend amount above the arrow tip: `TextStyleType.bend` (Edwin 8 pt
    /// normal, spatium-dependent), centered on the tip's x with the
    /// text's bottom on the tip's y.
    private static func drawLegacyBendLabel(
        _ text: String,
        anchor: CGPoint,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        guard !text.isEmpty else { return }
        let style = ResolvedTextStyle.resolve(.bend, metrics: metrics)
        if let layer = textLayer(
            text: text,
            at: anchor,
            size: style.pointSize,
            italic: style.isItalic,
            anchor: CGPoint(x: 0.5, y: 1.0),
            color: inkColor,
            font: style.ctFont,
            height: height,
        ) {
            parent.addSublayer(layer)
        }
    }
}
