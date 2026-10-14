#if os(macOS)
    import CoreGraphics
    import QuartzCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    /// The CALayer renderer draws a dynamic's own text from the runs layout placed, where layout measured their ink.
    @Suite("Dynamic rich text reaches the Apple renderers", .serialized)
    @MainActor
    struct DynamicRichTextRenderTests {
        private let _installApple = TestSupport.installApple

        /// What `drawElement` puts on a layer for `element` at `base: .zero`, as the Y-down box of its filled layers.
        /// `flipForPlatform` mirrors a macOS path about `height`, so undo it.
        @available(macOS 15.0, *)
        private static func drawnBox(_ element: LayoutElement, metrics: StaffMetrics) throws -> CGRect {
            let height: CGFloat = 2000
            let parent = CALayer()
            var context = ScoreLayerBuilder.BuildContext()
            ScoreLayerBuilder.drawElement(
                element, base: .zero, metrics: metrics, height: height, context: &context, into: parent,
            )
            let box = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                .filter { $0.fillColor != nil }
                .compactMap { $0.path?.boundingBoxOfPath }
                .reduce(CGRect.null) { $0.union($1) }
            try #require(!box.isNull)
            return CGRect(x: box.minX, y: height - box.maxY, width: box.width, height: box.height)
        }

        @available(macOS 15.0, *)
        @Test("a dynamic with its own text draws its runs where layout measured their ink")
        func richLayerMatchesInk() throws {
            _ = BravuraFont.register
            let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("dynamics"))
            let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 1200)
            let measure = try #require(document.systems.flatMap(\.measures).first { $0.measureIndex == 2 })
            let element = try #require(measure.elements.first { element in
                if case .textMark(.dynamic, _, _, _) = element { true } else { false }
            })
            guard case let .textMark(_, _, origin, rich?) = element else {
                Issue.record("bar 3's dynamic carries no runs")
                return
            }
            let ink = try #require(rich.inkRect(at: origin, anchor: LayoutRichText.anchor(for: .dynamic)))
            let drawn = try Self.drawnBox(element, metrics: document.metrics)
            #expect(abs(drawn.minX - ink.minX) < 0.5)
            #expect(abs(drawn.minY - ink.minY) < 0.5)
            #expect(abs(drawn.width - ink.width) < 0.5)
            #expect(abs(drawn.height - ink.height) < 0.5)
        }
    }
#endif
