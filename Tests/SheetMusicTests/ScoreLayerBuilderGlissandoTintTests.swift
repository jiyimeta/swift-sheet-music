#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if os(macOS)
        import CoreGraphics
        import QuartzCore
        import SheetMusicCore
        @testable import SheetMusicLayout
        @testable import SheetMusicUI
        import SwiftUI
        import Testing

        /// The CALayer path registers every stroke, wiggle glyph and label a glissando draws under its identity, so
        /// selecting one tints the whole line — both halves of a split one — and restores it untouched.
        @Suite("ScoreLayerBuilder — glissando tint")
        struct ScoreLayerBuilderGlissandoTintTests {
            private let _installApple = TestSupport.installApple

            private static let start = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
            )
            private static let item = ScoreItemID.element(.glissando(start: start))

            private static func line(wavy: Bool, text: String?, identified: Bool = true) -> LayoutElement {
                .glissandoLine(
                    fromOrigin: CGPoint(x: 40, y: 100), toOrigin: CGPoint(x: 240, y: 100),
                    wavy: wavy, text: text, start: identified ? start : nil,
                )
            }

            @available(macOS 15.0, *)
            private static func draw(_ element: LayoutElement) -> (CALayer, ScoreLayerBuilder.BuildContext) {
                let parent = CALayer()
                var context = ScoreLayerBuilder.BuildContext()
                ScoreLayerBuilder.drawElement(
                    element, base: .zero, metrics: ElementHitFixtures.metrics,
                    height: 300, context: &context, into: parent,
                )
                return (parent, context)
            }

            @Test(
                "Every layer a glissando draws registers under its identity",
                arguments: [(false, nil), (false, "gliss."), (true, "gliss.")] as [(Bool, String?)],
            )
            func registersEveryDrawnLayer(_ shape: (wavy: Bool, text: String?)) throws {
                guard #available(macOS 15.0, *) else { return }
                let (parent, context) = Self.draw(Self.line(wavy: shape.wavy, text: shape.text))
                let drawn = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                let layers = try #require(context.items[Self.item])
                #expect(!drawn.isEmpty)
                #expect(context.items.count == 1)
                #expect(Set(layers.map(ObjectIdentifier.init)) == Set(drawn.map(ObjectIdentifier.init)))
                // A wavy line draws one glyph per wiggle, and a label adds a layer of its own.
                #expect(layers.count > (shape.wavy || shape.text != nil ? 1 : 0))
            }

            @Test("A selected glissando tints, and deselecting restores the ink it was drawn with")
            func tintsAndRestores() throws {
                guard #available(macOS 15.0, *) else { return }
                let (_, context) = Self.draw(Self.line(wavy: true, text: "gliss."))
                let layers = try #require(context.items[Self.item])
                let fills = layers.map(\.fillColor)
                let strokes = layers.map(\.strokeColor)
                let state = SelectionRenderState.make(
                    selection: .single(Self.item), voiceColors: [0: .red],
                    score: ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score,
                )
                let tint = try #require(state.voiceColors[0])
                ScoreLayerBuilder.applySelection(items: context.items, previousSelection: .empty, newSelection: state)
                for (index, layer) in layers.enumerated() {
                    #expect(fills[index] != nil || strokes[index] != nil)
                    if fills[index] != nil { #expect(layer.fillColor == tint) }
                    if strokes[index] != nil { #expect(layer.strokeColor == tint) }
                }
                ScoreLayerBuilder.applySelection(items: context.items, previousSelection: state, newSelection: .empty)
                #expect(layers.map(\.fillColor) == fills)
                #expect(layers.map(\.strokeColor) == strokes)
            }

            @Test("A line the layout left unnamed draws and registers nothing")
            func unnamedLineRegistersNothing() {
                guard #available(macOS 15.0, *) else { return }
                let (parent, context) = Self.draw(Self.line(wavy: false, text: "gliss.", identified: false))
                #expect((parent.sublayers?.count ?? 0) > 0)
                #expect(context.items.isEmpty)
            }

            @Test("Both halves of a split glissando register under the one identity")
            func splitHalvesShareOneKey() throws {
                guard #available(macOS 15.0, *) else { return }
                let metrics = ElementHitFixtures.metrics
                let systems: [LayoutSystem] = [CGFloat(0), 200].map { y in
                    LayoutSystem(
                        origin: CGPoint(x: 0, y: y), size: .init(width: 200, height: 100), measures: [],
                        staffOrigins: [], partLabels: [], spanners: [], sp: metrics.sp,
                    )
                }
                let attached = LayoutEngine.attachGlissandi(
                    to: systems,
                    pairs: [LayoutEngine.GlissandoPair(
                        fromOrigin: CGPoint(x: 120, y: 50), toOrigin: CGPoint(x: 60, y: 250),
                        wavy: false, text: "gliss.", start: Self.start,
                        staff: Self.start.staff,
                    )],
                    metrics: metrics,
                )
                var items: [ScoreItemID: [CAShapeLayer]] = [:]
                for system in attached {
                    let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: metrics)
                    #expect(built.items.count == 1)
                    let layers = try #require(built.items[Self.item])
                    #expect(!layers.isEmpty)
                    items[Self.item, default: []].append(contentsOf: layers)
                }
                #expect(items.count == 1)
                #expect(try #require(items[Self.item]).count > 1)
            }
        }
    #endif
#endif
