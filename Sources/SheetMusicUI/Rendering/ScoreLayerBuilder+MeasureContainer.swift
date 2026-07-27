import QuartzCore
import SheetMusicCore
import SheetMusicLayout

/// Per-measure container layer construction, split out of
/// `ScoreLayerBuilder.swift` to keep that file under the project's
/// 300-line cap.
@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    /// Container layer for `measure`, spanning the system vertically and
    /// offset horizontally by the measure's `origin.x`.
    static func makeMeasureContainer(
        for measure: LayoutMeasure, systemSize: CGSize,
    ) -> CALayer {
        let container = CALayer()
        container.anchorPoint = .zero
        container.bounds = CGRect(origin: .zero, size: systemSize)
        container.position = CGPoint(x: measure.origin.x, y: 0)
        container.masksToBounds = false
        return container
    }

    /// Build one measure's visible layers into its own container.
    /// Children are drawn with the measure's X offset excluded (it lives
    /// on the container) but its Y offset applied, so the Y flip around
    /// the system height is unchanged.
    static func buildMeasure(
        _ measure: LayoutMeasure,
        metrics: StaffMetrics,
        systemSize: CGSize,
        showsInvisibleElements: Bool,
    ) -> (container: CALayer, items: [ScoreItemID: [CAShapeLayer]]) {
        let container = makeMeasureContainer(
            for: measure, systemSize: systemSize,
        )
        var ctx = BuildContext()
        ctx.showsInvisibleElements = showsInvisibleElements
        let base = CGPoint(x: 0, y: measure.origin.y)
        let height = systemSize.height
        for element in measure.elements {
            drawElement(
                element, base: base, metrics: metrics, height: height,
                context: &ctx, into: container,
            )
        }
        for el in measure.markers {
            drawElement(
                el, base: base, metrics: metrics, height: height,
                context: &ctx, into: container,
            )
        }
        for el in measure.jumps {
            drawElement(
                el, base: base, metrics: metrics, height: height,
                context: &ctx, into: container,
            )
        }
        return (container, ctx.items)
    }
}
