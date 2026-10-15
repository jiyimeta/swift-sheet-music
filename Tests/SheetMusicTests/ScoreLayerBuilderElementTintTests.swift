#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if os(macOS)
        import CoreGraphics
        import QuartzCore
        import SheetMusicCore
        @testable import SheetMusicLayout
        @testable import SheetMusicUI
        import SwiftUI
        import Testing

        #if !canImport(CoreGraphics)
            /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
            /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
            ///
            /// `private typealias` keeps these file-scoped — a module-scope alias here would collide
            /// with the same pattern in every other file in this target that needs it.
            private typealias CGFloat = SheetMusicLayout.CGFloat
            private typealias CGPoint = SheetMusicLayout.CGPoint
        #endif

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
                    selection: .single(item), voiceColors: [0: .red],
                    score: ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score,
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
                    selection: .single(item), voiceColors: [0: .red],
                    score: ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score,
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

            @Test("Pedal ink reaches above the skyline strip and out to its endpoint")
            func pedalInkRegression() throws {
                guard #available(macOS 15.0, *) else { return }
                let element = ElementHitFixtures.spanner(.pedal)
                let tester = ScoreHitTester(document: ElementHitFixtures.document([element]))
                let target = ScoreHitTarget.spanner(anchor: ElementHitFixtures.anchor, kind: .pedal)
                // The rect selection hits is the layout's own ink for this segment (label and line), moved into the
                // document's frame by the system and measure origins (+50, +50): derived, not retyped.
                guard case let .spannerSegment(_, from, to, _, _, _, _, label, detail) = element else {
                    Issue.record("expected a spannerSegment")
                    return
                }
                let ink = try #require(SpannerGeometry.textLineSegmentInk(
                    kind: .pedal, from: from, to: to, label: label, detail: detail, sp: ElementHitFixtures.metrics.sp,
                ))
                let rect = try #require(tester.elementHitRect(for: target))
                #expect(abs(rect.minX - (ink.minX + 50)) < 0.001)
                #expect(abs(rect.maxX - (ink.maxX + 50)) < 0.001)
                #expect(abs(rect.minY - (ink.minY + 50)) < 0.001)
                #expect(abs(rect.maxY - (ink.maxY + 50)) < 0.001)
                // The Ped label's ink sits above the line, the line runs to the endpoint (180 + 50).
                #expect(rect.minY < to.y + 50 - ElementHitFixtures.metrics.sp)
                #expect(rect.maxX >= to.x + 50 - 0.001)
                // Painted label ink, wherever the renderer put it, hits.
                let parent = CALayer()
                var context = ScoreLayerBuilder.BuildContext()
                ScoreLayerBuilder.drawElement(
                    element, base: .zero, metrics: ElementHitFixtures.metrics,
                    height: 200, context: &context, into: parent,
                )
                let labelLayer = try #require((parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                    .first { $0.strokeColor == nil && $0.fillColor != nil })
                let painted = try inkPoint(labelLayer)
                let point = CGPoint(x: painted.x + 50, y: 200 - painted.y + 50)
                #expect(tester.hitTest(at: point) == target)
                #expect(tester.itemID(at: point) == .element(.spanner(
                    anchor: ElementHitFixtures.anchor, kind: .pedal,
                )))
                // Nothing beyond the ink hits: past the line's end, and above the label — each 1 pt past the element
                // hit padding (`ScoreHitTester.elementHitTolerance`, 0.5 sp), which a click is allowed to land in.
                let clear = ElementHitFixtures.metrics.sp * 0.5 + 1
                #expect(tester.hitTest(at: CGPoint(x: rect.maxX + clear, y: to.y + 50)) == nil)
                #expect(tester.hitTest(at: CGPoint(x: rect.minX + 2, y: rect.minY - clear)) == nil)
                // The corner above the line and right of the label is inside the union but no part of the ink:
                // MuseScore's segment shape is its parts (`tlayout.cpp:6007-6026`), never their union.
                let parts = try #require(SpannerGeometry.textLineSegmentInkParts(
                    kind: .pedal, from: from, to: to, label: label, detail: detail, sp: ElementHitFixtures.metrics.sp,
                ))
                let labelPart = try #require(parts.first)
                let corner = CGPoint(x: (labelPart.maxX + ink.maxX) / 2 + 50, y: ink.minY + 1 + 50)
                #expect(rect.contains(corner))
                #expect(parts.filter { $0.offsetBy(dx: 50, dy: 50).contains(corner) }.isEmpty)
                #expect(tester.hitTest(at: corner) == nil)
            }

            @Test("The pedal label's and line's painted interiors hit at each staff size", arguments: [28, 40, 56])
            func pedalPaintedInteriors(staffSize: Int) throws {
                guard #available(macOS 15.0, *) else { return }
                let element = ElementHitFixtures.spanner(.pedal)
                let metrics = StaffMetrics(staffSize: CGFloat(staffSize))
                // The label glyph is filled and the line is stroked: two layers, each sampled where it paints.
                try checkPaintedInteriors(element, metrics: metrics, expectedLayers: 2, allowStroked: true)
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
                allowStroked: Bool = false,
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
                    try #require(allowStroked || layer.fillColor != nil)
                    // A stroked layer paints the outline of its stroke, so that is the area sampled.
                    let drawn = try #require(layer.path)
                    let path = layer.fillColor != nil ? drawn : drawn.copy(
                        strokingWithWidth: layer.lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10,
                    )
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

        extension ScoreLayerBuilderElementTintTests {
            @Test(
                "Selection-3 ink registers, tints and restores without touching neighbors",
                arguments: ElementHitFixtures.selection3Samples,
            )
            func selection3Tint(_ sample: ElementHitFixtures.Sample) throws {
                guard #available(macOS 15.0, *) else { return }
                let parent = CALayer()
                let neighbor = CAShapeLayer()
                neighbor.fillColor = CGColor(red: 0, green: 0.5, blue: 0, alpha: 1)
                parent.addSublayer(neighbor)
                var context = ScoreLayerBuilder.BuildContext()
                context.attach(neighbor, to: .note(ElementHitFixtures.noteID))
                ScoreLayerBuilder.drawElement(
                    sample.element, base: .zero, metrics: ElementHitFixtures.metrics,
                    height: 200, context: &context, into: parent,
                )
                let item = ScoreItemID.element(sample.id)
                let layers = try #require(context.items[item])
                // Each lens, slur stroke, single-line text path or mark's runs emit exactly one layer.
                try #require(layers.count == 1)
                #expect(context.items.count == 2)
                #expect(parent.sublayers?.count == 2)
                #expect(layers[0] === parent.sublayers?.last)
                if case .spannerSegment(.slur, _, _, _, _, _, _, _, _) = sample.element {
                    #expect(layers[0].fillColor == nil && layers[0].strokeColor != nil)
                } else {
                    #expect(layers[0].fillColor != nil && layers[0].strokeColor == nil)
                }
                try checkSelection3Tint(items: context.items, item: item, count: 1, neighbors: [neighbor])
            }

            @Test(
                "Unaddressed Selection-3 ink still draws and is never registered",
                arguments: ElementHitFixtures.selection3Samples,
            )
            func selection3WithoutIdentity(_ sample: ElementHitFixtures.Sample) throws {
                guard #available(macOS 15.0, *) else { return }
                let element: LayoutElement
                switch sample.element {
                case let .tieArc(from, to, above, _):
                    element = .tieArc(fromOrigin: from, toOrigin: to, above: above)
                case let .spannerSegment(kind, from, to, left, right, text, _, _, _):
                    element = .spannerSegment(
                        kind: kind, fromOrigin: from, toOrigin: to, continuesLeft: left,
                        continuesRight: right, text: text, anchor: nil,
                    )
                case let .jump(text, origin, _, richText, color, placement):
                    element = .jump(text: text, origin: origin, richText: richText, color: color, placement: placement)
                case let .marker(kind, text, origin, _, richText, color, placement):
                    element = .marker(
                        kind: kind, text: text, origin: origin, richText: richText, color: color, placement: placement,
                    )
                default:
                    Issue.record("Unexpected Selection-3 sample")
                    return
                }
                let parent = CALayer()
                var context = ScoreLayerBuilder.BuildContext()
                ScoreLayerBuilder.drawElement(
                    element, base: .zero, metrics: ElementHitFixtures.metrics,
                    height: 200, context: &context, into: parent,
                )
                let unaddressed = try #require(parent.sublayers?.first as? CAShapeLayer)
                #expect(parent.sublayers?.count == 1)
                #expect(context.items.isEmpty)
                ScoreLayerBuilder.drawElement(
                    sample.element, base: .zero, metrics: ElementHitFixtures.metrics,
                    height: 200, context: &context, into: parent,
                )
                try checkSelection3Tint(
                    items: context.items, item: .element(sample.id), count: 1, neighbors: [unaddressed],
                )
            }

            @Test("Both split-system tie and chord-slur lenses tint under one identity", arguments: [false, true])
            func selection3SplitSegments(isSlur: Bool) throws {
                guard #available(macOS 15.0, *) else { return }
                let sample = ElementHitFixtures.selection3Samples[isSlur ? 1 : 0]
                let systems: [LayoutSystem] = [CGFloat(0), 200].map { y in
                    LayoutSystem(
                        origin: CGPoint(x: 0, y: y), size: .init(width: 200, height: 100), measures: [],
                        staffOrigins: [], staffAddresses: [], staffGeometries: [], partLabels: [], spanners: [],
                        sp: 10,
                    )
                }
                let pairs: [LayoutEngine.TiePair] = [.init(
                    staff: 0, fromOrigin: CGPoint(x: 80, y: 80), toOrigin: CGPoint(x: 180, y: 280),
                    above: true, identity: sample.id,
                )]
                let attached = LayoutEngine.attachArcs(
                    to: systems, pairs: pairs, metrics: ElementHitFixtures.metrics,
                )
                let item = ScoreItemID.element(sample.id)
                var items: [ScoreItemID: [CAShapeLayer]] = [:]
                for system in attached {
                    let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: ElementHitFixtures.metrics)
                    let layers = try #require(built.items[item])
                    #expect(layers.count == 1)
                    #expect(built.items.count == 1)
                    for (id, ink) in built.items {
                        items[id, default: []].append(contentsOf: ink)
                    }
                }
                #expect(items.count == 1)
                // attachArcs emits one BEGIN and one END lens: two filled layers for one selection key.
                try checkSelection3Tint(items: items, item: item, count: 2, neighbors: [])
                // Also exercise append-under-an-existing-key within one renderer BuildContext.
                let combined = ElementHitFixtures.document([], spanners: attached.flatMap(\.spanners))
                let built = try ScoreLayerBuilder.buildSystemWithItems(
                    #require(combined.systems.first), metrics: combined.metrics,
                )
                #expect(built.items.count == 1)
                try checkSelection3Tint(items: built.items, item: item, count: 2, neighbors: [])
            }

            @Test(
                "Selection-3 identities restore supplied nondefault ink at the registration boundary",
                arguments: ElementHitFixtures.selection3Samples,
            )
            func selection3SuppliedInk(_ sample: ElementHitFixtures.Sample) throws {
                guard #available(macOS 15.0, *) else { return }
                // These layout payloads carry no authored color. This tests the shared restoration
                // contract, not a model-to-renderer color path that does not exist for these kinds.
                let layer = CAShapeLayer()
                layer.fillColor = CGColor(red: 0, green: 0.5, blue: 0, alpha: 1)
                layer.strokeColor = CGColor(red: 0.5, green: 0, blue: 0.5, alpha: 1)
                let item = ScoreItemID.element(sample.id)
                var context = ScoreLayerBuilder.BuildContext()
                context.attach(layer, to: item)
                try checkSelection3Tint(items: context.items, item: item, count: 1, neighbors: [])
            }

            @available(macOS 15.0, *)
            private func checkSelection3Tint(
                items: [ScoreItemID: [CAShapeLayer]], item: ScoreItemID, count: Int, neighbors: [CAShapeLayer],
            ) throws {
                let layers = try #require(items[item])
                try #require(layers.count == count)
                #expect(layers.allSatisfy { layer in !neighbors.contains { $0 === layer } })
                let fills = layers.map(\.fillColor)
                let strokes = layers.map(\.strokeColor)
                let neighborFills = neighbors.map(\.fillColor)
                let neighborStrokes = neighbors.map(\.strokeColor)
                let state = SelectionRenderState.make(
                    selection: .single(item), voiceColors: [0: .red],
                    score: ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score,
                )
                let tint = try #require(state.voiceColors[0])
                ScoreLayerBuilder.applySelection(items: items, previousSelection: .empty, newSelection: state)
                for (index, layer) in layers.enumerated() {
                    #expect(fills[index] != nil || strokes[index] != nil)
                    if fills[index] != nil { #expect(layer.fillColor == tint) }
                    if strokes[index] != nil { #expect(layer.strokeColor == tint) }
                }
                #expect(neighbors.map(\.fillColor) == neighborFills)
                #expect(neighbors.map(\.strokeColor) == neighborStrokes)
                ScoreLayerBuilder.applySelection(items: items, previousSelection: state, newSelection: .empty)
                #expect(layers.map(\.fillColor) == fills)
                #expect(layers.map(\.strokeColor) == strokes)
                #expect(neighbors.map(\.fillColor) == neighborFills)
                #expect(neighbors.map(\.strokeColor) == neighborStrokes)
            }
        }
    #endif
#endif
