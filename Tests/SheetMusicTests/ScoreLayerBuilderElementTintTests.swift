#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if os(macOS)
        import CoreGraphics
        import QuartzCore
        import SheetMusicCore
        @testable import SheetMusicLayout
        @testable import SheetMusicUI
        import SwiftUI
        import Testing

        @Suite("ScoreLayerBuilder — element ink and tint")
        struct ScoreLayerBuilderElementTintTests {
            private let _installApple = TestSupport.installApple

            /// Checks one sampled painted point from the first layer against the editing address.
            /// Passing establishes agreement at that point, not containment of every component's ink.
            @Test("Painted ink round-trips to the editing address", arguments: ElementHitFixtures.samples)
            func inkToCommand(_ sample: ElementHitFixtures.Sample) throws {
                guard #available(macOS 15.0, *) else { return }
                let parent = CALayer()
                var context = ScoreLayerBuilder.BuildContext()
                ScoreLayerBuilder.drawElement(
                    sample.element, base: .zero, metrics: ElementHitFixtures.metrics,
                    height: 200, context: &context, into: parent,
                )
                let layers = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                let layer = try #require(layers.first)
                let ink = try inkPoint(layer)
                // drawElement used a zero base and a 200-point Y flip; the document adds (50,50).
                let point = CGPoint(x: ink.x + 50, y: 200 - ink.y + 50)
                let tester = ScoreHitTester(document: ElementHitFixtures.document([sample.element]))
                let target = try #require(tester.hitTest(at: point))
                #expect(target == ScoreHitTarget(elementID: sample.id))
                let item = try #require(tester.itemID(at: point))
                #expect(item == .element(sample.id))
                #expect(target.selectableItem == item)
                #expect(try #require(tester.elementHitRect(for: target)).contains(point))
                try ElementHitCommandChecks.apply(#require(item.elementID))
            }

            @Test(
                "Every painted component tints and restores",
                arguments: ElementHitFixtures.samples + ElementHitFixtures.variants,
            )
            func allComponentsTint(_ sample: ElementHitFixtures.Sample) throws {
                guard #available(macOS 15.0, *) else { return }
                let doc = ElementHitFixtures.document([sample.element])
                let system = try #require(doc.systems.first)
                let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: doc.metrics)
                let item = ScoreItemID.element(sample.id)
                let layers = try #require(built.items[item])
                let container = try #require(built.measureContainers[0])
                let drawn = (container.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                #expect(!drawn.isEmpty)
                #expect(Set(layers.map(ObjectIdentifier.init)) == Set(drawn.map(ObjectIdentifier.init)))
                let beforeFill = layers.map(\.fillColor)
                let beforeStroke = layers.map(\.strokeColor)
                let state = SelectionRenderState.make(
                    selection: .single(item), voiceColors: [0: .red], score: EditingFixtures.twoConsecutiveC4Chords(),
                )
                let tint = try #require(state.voiceColors[0])
                ScoreLayerBuilder.applySelection(items: built.items, previousSelection: .empty, newSelection: state)
                for (index, layer) in layers.enumerated() {
                    #expect(beforeFill[index] != nil || beforeStroke[index] != nil)
                    if beforeFill[index] != nil { #expect(layer.fillColor == tint) }
                    if beforeStroke[index] != nil { #expect(layer.strokeColor == tint) }
                }
                ScoreLayerBuilder.applySelection(items: built.items, previousSelection: state, newSelection: .empty)
                #expect(layers.map(\.fillColor) == beforeFill)
                #expect(layers.map(\.strokeColor) == beforeStroke)
            }

            @Test("The element registration boundary preserves supplied fill and stroke ink")
            func suppliedInkRestores() throws {
                guard #available(macOS 15.0, *) else { return }
                // These layout kinds do not carry author colors yet. Exercise the registration boundary
                // with supplied ink, without inventing a model-to-layout color path in this feature.
                let layer = CAShapeLayer()
                let fill = CGColor(red: 0, green: 0.5, blue: 0, alpha: 1)
                let stroke = CGColor(red: 0.5, green: 0, blue: 0.5, alpha: 1)
                layer.fillColor = fill
                layer.strokeColor = stroke
                let item = ScoreItemID.element(.dynamic(anchor: ElementHitFixtures.anchor))
                var context = ScoreLayerBuilder.BuildContext()
                context.attach(layer, to: item)
                let state = SelectionRenderState.make(
                    selection: .single(item), voiceColors: [0: .red], score: EditingFixtures.twoConsecutiveC4Chords(),
                )
                let tint = try #require(state.voiceColors[0])
                ScoreLayerBuilder.applySelection(items: context.items, previousSelection: .empty, newSelection: state)
                #expect(layer.fillColor == tint && layer.strokeColor == tint)
                ScoreLayerBuilder.applySelection(items: context.items, previousSelection: state, newSelection: .empty)
                #expect(layer.fillColor == fill && layer.strokeColor == stroke)
            }

            @Test("Unaddressed ink draws without registering itself or neighboring ink")
            func absentIdentity() {
                guard #available(macOS 15.0, *) else { return }
                let parent = CALayer()
                let neighbor = CAShapeLayer()
                neighbor.fillColor = CGColor(gray: 0.5, alpha: 1)
                parent.addSublayer(neighbor)
                var context = ScoreLayerBuilder.BuildContext()
                ScoreLayerBuilder.drawElement(
                    ElementHitFixtures.bar("end-repeat", measureIndex: nil), base: .zero,
                    metrics: ElementHitFixtures.metrics, height: 200, context: &context, into: parent,
                )
                #expect((parent.sublayers?.count ?? 0) > 1)
                #expect(context.items.isEmpty)
                ScoreLayerBuilder.drawElement(
                    ElementHitFixtures.bar("double"), base: .zero,
                    metrics: ElementHitFixtures.metrics, height: 200, context: &context, into: parent,
                )
                let registered = context.items.values.flatMap(\.self)
                #expect(registered.count == 2)
                #expect(!registered.contains { $0 === neighbor })
            }

            @Test("System spanner components register under the source identity")
            func systemSpannersRegister() throws {
                guard #available(macOS 15.0, *) else { return }
                for sample in ElementHitFixtures.samples {
                    guard case .spanner = sample.id else { continue }
                    let doc = ElementHitFixtures.document([], spanners: [sample.element])
                    let system = try #require(doc.systems.first)
                    let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: doc.metrics)
                    let layers = try #require(built.items[.element(sample.id)])
                    #expect(!layers.isEmpty)
                    let drawn = (built.root.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                    #expect(Set(layers.map(ObjectIdentifier.init)) == Set(drawn.map(ObjectIdentifier.init)))
                }
            }

            @Test("Pedal ink reaches above the skyline strip and beyond its endpoint")
            func pedalInkRegression() throws {
                guard #available(macOS 15.0, *) else { return }
                let element = ElementHitFixtures.spanner(.pedal)
                let tester = ScoreHitTester(document: ElementHitFixtures.document([element]))
                let target = ScoreHitTarget.spanner(anchor: ElementHitFixtures.anchor, kind: .pedal)
                // The original failure is actual Ped. ink, 3.44 points above the skyline strip.
                let point = CGPoint(x: 150.38, y: 119.06)
                #expect(tester.hitTest(at: point) == target)
                #expect(tester.itemID(at: point) == .element(.spanner(
                    anchor: ElementHitFixtures.anchor, kind: .pedal,
                )))
                let rect = try #require(tester.elementHitRect(for: target))
                // Bravura at 40 pt: Ped. bbox (0,-0.32,40.76,22.52); release bbox (0,0,18,18).
                // Leading anchors (130,130) and (230,130), baseline offset 0: union below.
                #expect(abs(rect.minX - 130) < 0.001)
                #expect(abs(rect.maxX - 248) < 0.001)
                #expect(abs(rect.minY - 107.8) < 0.001)
                #expect(abs(rect.maxY - 130.32) < 0.001)
                #expect(tester.hitTest(at: CGPoint(x: 200, y: 125)) == nil)
            }

            @Test("Both pedal glyphs' sampled painted interiors hit at each staff size", arguments: [28, 40, 56])
            func pedalPaintedInteriors(staffSize: Int) throws {
                guard #available(macOS 15.0, *) else { return }
                let element = ElementHitFixtures.spanner(.pedal)
                let metrics = StaffMetrics(staffSize: CGFloat(staffSize))
                try checkPaintedInteriors(element, metrics: metrics, expectedLayers: 2)
            }

            @Test("Every signature glyph's sampled ink round-trips", arguments: ElementHitFixtures.signatures)
            func signaturePaintedInteriors(_ sample: ElementHitFixtures.Sample) throws {
                guard #available(macOS 15.0, *) else { return }
                for staffSize in [28, 40, 56] {
                    try checkPaintedInteriors(sample.element, metrics: StaffMetrics(staffSize: CGFloat(staffSize)))
                }
            }

            /// Samples actual filled interiors on every layer; finite sampling is not a containment proof.
            @available(macOS 15.0, *)
            private func checkPaintedInteriors(
                _ element: LayoutElement, metrics: StaffMetrics, expectedLayers: Int? = nil,
            ) throws {
                let parent = CALayer()
                var context = ScoreLayerBuilder.BuildContext()
                ScoreLayerBuilder.drawElement(
                    element, base: .zero, metrics: metrics,
                    height: 200, context: &context, into: parent,
                )
                let layers = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                #expect(!layers.isEmpty)
                if let expectedLayers { #expect(layers.count == expectedLayers) }
                let tester = ScoreHitTester(document: ElementHitFixtures.document([element], metrics: metrics))
                let id = try #require(element.elementID)
                let target = ScoreHitTarget(elementID: id)
                let highlight = try #require(tester.elementHitRect(for: target))
                for layer in layers {
                    try #require(layer.fillColor != nil)
                    let path = try #require(layer.path)
                    let box = path.boundingBoxOfPath
                    var sampled = 0
                    for row in 0 ..< 17 {
                        for column in 0 ..< 17 {
                            let ink = CGPoint(
                                x: box.minX + (CGFloat(column) + 0.5) * box.width / 17,
                                y: box.minY + (CGFloat(row) + 0.5) * box.height / 17,
                            )
                            guard path.contains(ink) else { continue }
                            sampled += 1
                            let point = CGPoint(x: ink.x + 50, y: 200 - ink.y + 50)
                            #expect(tester.hitTest(at: point) == target)
                            #expect(tester.itemID(at: point) == .element(id))
                            #expect(highlight.contains(point))
                        }
                    }
                    #expect(sampled > 0)
                    let ink = try inkPoint(layer)
                    let item = try #require(tester.itemID(at: CGPoint(x: ink.x + 50, y: 200 - ink.y + 50)))
                    try ElementHitCommandChecks.apply(#require(item.elementID))
                }
            }

            private func inkPoint(_ layer: CAShapeLayer) throws -> CGPoint {
                let path = try #require(layer.path)
                let painted = layer.fillColor != nil ? path : path.copy(
                    strokingWithWidth: layer.lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10,
                )
                let box = painted.boundingBoxOfPath
                // Sample actual rendered ink, independently of hit-test and skyline geometry.
                // Search outward from the center so a hollow glyph does not yield a point in its counter.
                let offsets = [0] + (1 ... 20).flatMap { [$0, -$0] }
                for y in offsets {
                    for x in offsets {
                        let point = CGPoint(
                            x: box.midX + CGFloat(x) * box.width / 42,
                            y: box.midY + CGFloat(y) * box.height / 42,
                        )
                        if painted.contains(point) { return point }
                    }
                }
                throw InkProbeError.noInterior
            }

            private enum InkProbeError: Error {
                case noInterior
            }
        }
    #endif
#endif
