import CoreGraphics
import QuartzCore
import SheetMusicCore
import SheetMusicLayout

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    /// Draws a rectangular outline around every staff × time region
    /// that contains a selected item (note or rest) on this system.
    /// Called when `selection.drawRangeBox` is true.
    ///
    /// The rectangle is `LayoutSystem.rangeBoxRect(selectedIDs:metrics:)`
    /// — portable, so a renderer without Core Animation draws the same
    /// box — which says how its edges are measured: the time the
    /// selection occupies rather than the ink it is drawn with, and the
    /// end staves' own line spans.
    static func drawRangeBoxes(
        system: LayoutSystem,
        selection: SelectionRenderState,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        guard let rect = system.rangeBoxRect(
            selectedIDs: selection.selectedIDs, metrics: metrics,
        ) else { return }

        let path = CGPath(rect: rect, transform: nil)
        #if os(macOS)
            // LayoutEngine emits Y-down; macOS CALayer is Y-up. Flip
            // around `height` to match the other layers built in the
            // same tree (see `ScoreLayerBuilder.flipForPlatform`).
            var flip = CGAffineTransform(
                a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height,
            )
            let drawPath = path.copy(using: &flip) ?? path
        #else
            let drawPath = path
        #endif
        let layer = CAShapeLayer()
        layer.path = drawPath
        layer.strokeColor = selection.rangeBoxColor
        layer.fillColor = nil
        layer.lineWidth = metrics.rangeBoxLineWidth
        layer.masksToBounds = false
        parent.addSublayer(layer)
    }
}
