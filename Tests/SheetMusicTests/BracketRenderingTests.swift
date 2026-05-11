#if canImport(QuartzCore)
    import CoreGraphics
    import Foundation
    import QuartzCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    struct BracketRenderingTests {
        /// Counts shape (stroke) sublayers and text sublayers in a tree.
        private static func countLayerKinds(
            _ root: CALayer,
        ) -> (shapes: Int, texts: Int) {
            var shapes = 0, texts = 0
            func walk(_ layer: CALayer) {
                if layer is CAShapeLayer { shapes += 1 }
                if layer is CATextLayer { texts += 1 }
                for sub in layer.sublayers ?? [] {
                    walk(sub)
                }
            }
            walk(root)
            return (shapes, texts)
        }

        @available(macOS 15.0, iOS 16.0, *)
        private static func sampleSystem(
            type: BracketType,
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
                    column: 0,
                    staffCount: 2,
                )],
                spanners: [],
                sp: metrics.sp,
            )
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func normalBracketEmitsStrokes() {
            let metrics = StaffMetrics(staffSize: 28)
            let system = Self.sampleSystem(type: .normal)
            let root = CALayer()
            ScoreLayerBuilder.drawBrackets(
                system: system, metrics: metrics,
                height: system.size.height, into: root,
            )
            let counts = Self.countLayerKinds(root)
            #expect(counts.shapes >= 1)
            #expect(counts.texts == 0)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func braceEmitsFilledGlyphPath() {
            let metrics = StaffMetrics(staffSize: 28)
            let system = Self.sampleSystem(type: .brace)
            let root = CALayer()
            ScoreLayerBuilder.drawBrackets(
                system: system, metrics: metrics,
                height: system.size.height, into: root,
            )
            let counts = Self.countLayerKinds(root)
            // Brace draws as a filled CAShapeLayer (the SMuFL glyph
            // path), not a CATextLayer.
            #expect(counts.shapes >= 1)
            #expect(counts.texts == 0)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func normalBracketEmitsSpineAndTwoCaps() {
            let metrics = StaffMetrics(staffSize: 28)
            let system = Self.sampleSystem(type: .normal)
            let root = CALayer()
            ScoreLayerBuilder.drawBrackets(
                system: system, metrics: metrics,
                height: system.size.height, into: root,
            )
            let counts = Self.countLayerKinds(root)
            // 1 stroke (spine) + 2 fills (bracketTop + bracketBottom)
            // = 3 shape layers. No text layers.
            #expect(counts.shapes == 3)
            #expect(counts.texts == 0)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func lineBracketHasNoSerifs() {
            let metrics = StaffMetrics(staffSize: 28)
            let system = Self.sampleSystem(type: .line)
            let root = CALayer()
            ScoreLayerBuilder.drawBrackets(
                system: system, metrics: metrics,
                height: system.size.height, into: root,
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
                sp: metrics.sp,
            )
            let root = CALayer()
            ScoreLayerBuilder.drawBrackets(
                system: system, metrics: metrics,
                height: system.size.height, into: root,
            )
            #expect((root.sublayers ?? []).isEmpty)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func systemBarSpansAllStaves() {
            let metrics = StaffMetrics(staffSize: 28)
            let system = LayoutSystem(
                origin: .zero,
                size: CGSize(width: 200, height: 200),
                measures: [],
                staffOrigins: [
                    CGPoint(x: 60, y: 20),
                    CGPoint(x: 60, y: 80),
                ],
                partLabels: [],
                brackets: [],
                spanners: [],
                sp: metrics.sp,
            )
            let root = CALayer()
            ScoreLayerBuilder.drawSystemBar(
                system: system, metrics: metrics,
                height: system.size.height, into: root,
            )
            // Exactly one shape layer for the joining bar.
            let counts = Self.countLayerKinds(root)
            #expect(counts.shapes == 1)
            #expect(counts.texts == 0)
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func systemBarEmptyStaffOriginsEmitsNothing() {
            let metrics = StaffMetrics(staffSize: 28)
            let system = LayoutSystem(
                origin: .zero,
                size: CGSize(width: 200, height: 200),
                measures: [],
                staffOrigins: [],
                partLabels: [],
                brackets: [],
                spanners: [],
                sp: metrics.sp,
            )
            let root = CALayer()
            ScoreLayerBuilder.drawSystemBar(
                system: system, metrics: metrics,
                height: system.size.height, into: root,
            )
            #expect((root.sublayers ?? []).isEmpty)
        }
    }
#endif
