#if os(macOS)
    import CoreGraphics
    import QuartzCore
    import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// The CALayer renderer's half of the barline span.
    ///
    /// `LayoutElement.barLine` carries `halfHeight`, but `drawBarLine`
    /// takes it as a plain parameter — nothing forces the body to
    /// actually use it, and before this change the ±2 sp was written
    /// down here independently of the engine. The layout-level
    /// assertions in `StaffLineCountLayoutTests` all pass on a renderer
    /// that keeps deriving the span from `metrics`, because they never
    /// reach a renderer at all.
    ///
    /// The half-height under test (`sp`, what a three-line staff gets)
    /// is deliberately NOT `sp * 2`: a renderer still using the old
    /// constant produces a stroke twice as tall, which this catches.
    /// The corpus pixel gate rasterizes this same layer tree, so a real
    /// regression would also show up there — but only for scores that
    /// happen to contain a non-five-line staff.
    @Suite("Bar line span — CALayer renderer")
    struct BarLineSpanRendererTests {
        @Test("drawBarLine strokes origin.y ± halfHeight")
        func strokeFollowsTheSuppliedHalfHeight() throws {
            guard #available(macOS 15.0, *) else { return }
            let metrics = StaffMetrics(staffSize: 28) // sp = 7
            let originY: CGFloat = 100
            let halfHeight = metrics.sp // a three-line staff's span

            let parent = CALayer()
            ScoreLayerBuilder.drawBarLine(
                subtype: nil,
                origin: CGPoint(x: 50, y: originY),
                halfHeight: halfHeight,
                metrics: metrics,
                height: 0,
                into: parent,
            )

            let shape = try #require(
                parent.sublayers?.compactMap { $0 as? CAShapeLayer }.first,
            )
            let box = try #require(shape.path?.boundingBox)
            #expect(abs(box.height - halfHeight * 2) < 0.001)
            // `strokeLayer` flips Y for the platform, so compare the
            // stroke's center to `originY` by magnitude rather than
            // assuming a direction.
            #expect(abs(abs(box.midY) - originY) < 0.001)
        }
    }
#endif
