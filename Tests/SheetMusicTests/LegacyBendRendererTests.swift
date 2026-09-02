#if os(macOS)
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    /// The Apple render paths for `LayoutElement.legacyBend`: the shared
    /// geometry helpers of `LegacyBendRenderer` and the CALayer builder
    /// that consumes them. Pixel truth lives in the Mac example app; this
    /// only pins the ink each piece kind produces.
    @Suite("Legacy MS3 bend rendering")
    struct LegacyBendRendererTests {
        private let _installApple = TestSupport.installApple

        private static let metrics = StaffMetrics(staffSize: 20)

        /// Two disjoint legs plus a flat plateau: the outline path must
        /// carry a `move` per piece, never joining leg ends that the
        /// geometry left apart.
        @Test("the outline path strokes every line and curve")
        func outlineCoversLinesAndCurves() {
            guard #available(macOS 15.0, *) else { return }
            let shape = LegacyBendShape(pieces: [
                .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: -40)),
                .curve(
                    from: CGPoint(x: 0, y: -40),
                    control1: CGPoint(x: 3, y: -40),
                    control2: CGPoint(x: 5, y: -38),
                    to: CGPoint(x: 5, y: -30),
                ),
                .arrow(tip: CGPoint(x: 5, y: -30), up: false),
                .label(text: "full", anchor: CGPoint(x: 0, y: -40)),
            ])
            let path = LegacyBendRenderer.outlinePath(for: shape)
            #expect(!path.isEmpty)
            // Arrow and label contribute nothing to the stroked outline,
            // so the bbox is exactly the line + curve hull: an arrowhead
            // at the curve's far end would have pushed maxX past 5.
            let box = path.boundingBoxOfPath
            #expect(abs(box.minY - -40) < 0.001)
            #expect(abs(box.maxY - 0) < 0.001)
            #expect(abs(box.minX - 0) < 0.001)
            #expect(abs(box.maxX - 5) < 0.001)
        }

        @Test("an empty shape strokes nothing")
        func emptyShapeHasEmptyOutline() {
            guard #available(macOS 15.0, *) else { return }
            #expect(LegacyBendRenderer.outlinePath(
                for: LegacyBendShape(pieces: []),
            ).isEmpty)
        }

        /// `tdraw.cpp:963-966`: base `aw` behind the tip, `aw` wide,
        /// closed (filled, not stroked).
        @Test("arrowheads are closed triangles pointing off the tip")
        func arrowTriangleGeometry() {
            guard #available(macOS 15.0, *) else { return }
            let tip = CGPoint(x: 10, y: -20)
            let up = LegacyBendRenderer.arrowPath(
                tip: tip, up: true, arrowWidth: 4,
            )
            let upBox = up.boundingBoxOfPath
            #expect(abs(upBox.width - 4) < 0.001)
            #expect(abs(upBox.height - 4) < 0.001)
            // Y-down frame: an up-arrow's base sits BELOW its apex.
            #expect(abs(upBox.minY - tip.y) < 0.001)

            let down = LegacyBendRenderer.arrowPath(
                tip: tip, up: false, arrowWidth: 4,
            )
            let downBox = down.boundingBoxOfPath
            #expect(abs(downBox.maxY - tip.y) < 0.001)
            #expect(abs(downBox.width - 4) < 0.001)
        }

        // MARK: - CALayer path

        @MainActor
        @Test("the layer builder emits a round-pen stroke, fills and text")
        func layerBuilderEmitsEveryPieceKind() {
            guard #available(macOS 15.0, *) else { return }
            _ = BravuraFont.register
            let shape = LegacyBendShape(pieces: [
                .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: -40)),
                .arrow(tip: CGPoint(x: 0, y: -40), up: true),
                .label(text: "full", anchor: CGPoint(x: 0, y: -40)),
                .curve(
                    from: CGPoint(x: 0, y: -40),
                    control1: CGPoint(x: 3, y: -40),
                    control2: CGPoint(x: 5, y: -38),
                    to: CGPoint(x: 5, y: -10),
                ),
                .arrow(tip: CGPoint(x: 5, y: -10), up: false),
            ])
            let parent = CALayer()
            ScoreLayerBuilder.drawLegacyBend(
                shape: shape, metrics: Self.metrics,
                height: 200, into: parent,
            )
            let shapes = (parent.sublayers ?? [])
                .compactMap { $0 as? CAShapeLayer }
            // 1 stroked outline + 2 arrow fills + 1 text fill.
            #expect(shapes.count == 4)

            let stroked = shapes.filter { $0.strokeColor != nil }
            #expect(stroked.count == 1)
            guard let outline = stroked.first else { return }
            #expect(outline.lineCap == .round)
            #expect(outline.lineJoin == .round)
            #expect(outline.fillColor == nil)
            #expect(abs(
                outline.lineWidth
                    - Self.metrics.sp * LegacyBendGeometry.lineThicknessSp,
            ) < 0.0001)

            // Everything else is filled with no stroke.
            let filled = shapes.filter {
                $0.strokeColor == nil && $0.fillColor != nil
            }
            #expect(filled.count == 3)
            #expect(filled.allSatisfy { ($0.path?.isEmpty == false) })
        }

        @MainActor
        @Test("a bend-free shape adds no sublayers")
        func emptyShapeAddsNothing() {
            guard #available(macOS 15.0, *) else { return }
            let parent = CALayer()
            ScoreLayerBuilder.drawLegacyBend(
                shape: LegacyBendShape(pieces: []),
                metrics: Self.metrics, height: 200, into: parent,
            )
            #expect((parent.sublayers ?? []).isEmpty)
        }

        /// End to end: the canonical MS3 fixture's bends reach the built
        /// system tree. The round cap/join is unique to the bend pen in
        /// this package, so it doubles as the signature that the bend —
        /// and not some other spanner — put the ink there.
        @MainActor
        @Test("the canonical fixture's bends reach the system layer tree")
        func fixtureBendsProduceLayers() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = BravuraFont.register
            let score = try MSCXParser.parse(
                MSCXFixtureLoader.mscxData("legacybend_ms3_canonical"),
            )
            let document = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 1200,
            )
            var roundPens = 0
            for system in document.systems {
                let tree = ScoreLayerBuilder.buildSystem(
                    system, metrics: document.metrics,
                )
                roundPens += Self.allLayers(tree)
                    .compactMap { $0 as? CAShapeLayer }
                    .filter {
                        $0.strokeColor != nil && $0.lineCap == .round
                    }
                    .count
            }
            // One stroked outline per bend; the fixture carries six.
            #expect(roundPens == 6)
        }

        private static func allLayers(_ root: CALayer) -> [CALayer] {
            var all: [CALayer] = [root]
            for child in root.sublayers ?? [] {
                all.append(contentsOf: allLayers(child))
            }
            return all
        }
    }
#endif
