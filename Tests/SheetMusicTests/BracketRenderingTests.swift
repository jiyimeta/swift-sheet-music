#if canImport(QuartzCore)
    import CoreGraphics
    import Foundation
    import QuartzCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite struct BracketRenderingTests {
        /// Counts shape (stroke) sublayers and text sublayers in a tree.
        private static func countLayerKinds(
            _ root: CALayer
        ) -> (shapes: Int, texts: Int) {
            var shapes = 0, texts = 0
            func walk(_ layer: CALayer) {
                if layer is CAShapeLayer { shapes += 1 }
                if layer is CATextLayer { texts += 1 }
                for sub in layer.sublayers ?? [] { walk(sub) }
            }
            walk(root)
            return (shapes, texts)
        }

        @available(macOS 15.0, iOS 16.0, *)
        private static func sampleSystem(
            type: BracketType
        ) -> LayoutSystem {
            let metrics = StaffMetrics(staffSize: 28)
            return LayoutSystem(
                origin: .zero,
                size: CGSize(width: 200, height: 200),
                measures: [],
                staffOrigins: [
                    CGPoint(x: 60, y: 20),
                    CGPoint(x: 60, y: 80),
                ],
                partLabels: [],
                brackets: [LayoutBracket(
                    type: type,
                    topY: 20,
                    bottomY: 80 + metrics.staffHeight,
                    column: 0
                )],
                spanners: [],
                sp: metrics.sp
            )
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func normalBracketEmitsStrokes() {
            let metrics = StaffMetrics(staffSize: 28)
            let system = Self.sampleSystem(type: .normal)
            let root = CALayer()
            ScoreLayerBuilder.drawBrackets(
                system: system, metrics: metrics,
                height: system.size.height, into: root
            )
            let counts = Self.countLayerKinds(root)
            #expect(counts.shapes >= 1)
            #expect(counts.texts == 0)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func braceBracketEmitsTextLayer() {
            let metrics = StaffMetrics(staffSize: 28)
            let system = Self.sampleSystem(type: .brace)
            let root = CALayer()
            ScoreLayerBuilder.drawBrackets(
                system: system, metrics: metrics,
                height: system.size.height, into: root
            )
            let counts = Self.countLayerKinds(root)
            #expect(counts.texts >= 1)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func lineBracketHasNoSerifs() {
            let metrics = StaffMetrics(staffSize: 28)
            let system = Self.sampleSystem(type: .line)
            let root = CALayer()
            ScoreLayerBuilder.drawBrackets(
                system: system, metrics: metrics,
                height: system.size.height, into: root
            )
            let counts = Self.countLayerKinds(root)
            // Just the spine — exactly 1 stroke layer, no serif strokes.
            #expect(counts.shapes == 1)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func emptyBracketsEmitsNothing() {
            let metrics = StaffMetrics(staffSize: 28)
            let system = LayoutSystem(
                origin: .zero,
                size: CGSize(width: 200, height: 200),
                measures: [],
                staffOrigins: [.init(x: 60, y: 20)],
                partLabels: [],
                brackets: [],
                spanners: [],
                sp: metrics.sp
            )
            let root = CALayer()
            ScoreLayerBuilder.drawBrackets(
                system: system, metrics: metrics,
                height: system.size.height, into: root
            )
            #expect((root.sublayers ?? []).isEmpty)
        }
    }
#endif
