#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import Testing

    @Suite("Text ink geometry")
    @MainActor
    struct TextInkGeometryTests {
        private let _installApple = TestSupport.installApple
        private let metrics = ElementHitFixtures.metrics

        /// The renderer is the independent oracle: replacing ink by the typographic band,
        /// dropping bold, or anchoring only the first line must fail this comparison.
        @Test(arguments: ["g", "A", "A\ng", "A\n\ng", " A "])
        func staffTextHighlightMatchesRenderedPaths(text: String) throws {
            guard #available(macOS 15.0, *) else { return }
            let element = LayoutElement.staffText(
                text: text, origin: ElementHitFixtures.origin, color: nil,
                style: .staffText, anchor: ElementHitFixtures.anchor,
            )
            try expectHighlightMatchesPaths(element)
        }

        @Test(arguments: [TextFrameType.none, .rectangle, .circle], ["A", "Ag", "B\nframe", "A\ng", "A\n\ng"])
        func rehearsalHighlightIncludesFrameStroke(frame: TextFrameType, text: String) throws {
            guard #available(macOS 15.0, *) else { return }
            let element = LayoutElement.rehearsalMark(
                text: text, origin: ElementHitFixtures.origin,
                frame: frame, color: nil, measureIndex: 0,
            )
            try expectHighlightMatchesPaths(element)
        }

        @Test func pedalSkylineContainsBothRenderedGlyphs() throws {
            guard #available(macOS 15.0, *) else { return }
            let element = ElementHitFixtures.spanner(.pedal)
            let shape = try #require(LayoutElementShape.shape(for: element, id: 0, xOffset: 0, metrics: metrics))
            #expect(shape.rects.count == 2)
            let parent = CALayer()
            var context = ScoreLayerBuilder.BuildContext()
            ScoreLayerBuilder.drawElement(
                element,
                base: .zero,
                metrics: metrics,
                height: 200,
                context: &context,
                into: parent,
            )
            let layers = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
            #expect(layers.count == 2)
            for layer in layers {
                let bounds = try #require(layer.path).boundingBoxOfPath
                let drawn = CGRect(x: bounds.minX, y: 200 - bounds.maxY, width: bounds.width, height: bounds.height)
                #expect(shape.rects.contains { $0.rect.insetBy(dx: -0.001, dy: -0.001).contains(drawn) })
            }
        }

        /// Actual rendered outlines must fit inside the stroke with the default 0.5 sp clearance.
        /// A renderer/selection parity assertion alone cannot catch ink crossing its own frame.
        @Test(arguments: ["A", "I", "-", "B\nframe", "A\n\ng"])
        func rehearsalCircleClearsRenderedInk(text: String) throws {
            guard #available(macOS 15.0, *) else { return }
            let element = LayoutElement.rehearsalMark(
                text: text, origin: ElementHitFixtures.origin, frame: .circle, color: nil, measureIndex: 0,
            )
            let parent = CALayer()
            var context = ScoreLayerBuilder.BuildContext()
            ScoreLayerBuilder.drawElement(
                element, base: .zero, metrics: metrics, height: 200, context: &context, into: parent,
            )
            let layers = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
            let textLayer = try #require(layers.first { $0.fillColor != nil })
            let frameLayer = try #require(layers.first { $0.fillColor == nil })
            let ink = try #require(textLayer.path).boundingBoxOfPath
            let circle = try #require(frameLayer.path).boundingBoxOfPath
            #expect(abs(circle.width - circle.height) < 0.001)
            let innerRadius = circle.width / 2 - frameLayer.lineWidth / 2
            for x in [ink.minX, ink.maxX] {
                for y in [ink.minY, ink.maxY] {
                    let distance = hypot(x - circle.midX, y - circle.midY)
                    #expect(innerRadius - distance >= metrics.sp * 0.5 - 0.001)
                }
            }
            if text == "-" {
                let font = TextInkOracle.font(
                    size: TextInkGeometry.font(for: .rehearsalMark, metrics: metrics).pointSize, bold: true,
                )
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                let width = max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), CTFontGetSize(font) * 0.5)
                let height = CTFontGetAscent(font) + CTFontGetDescent(font)
                #expect(abs(circle.width - max(width, height) - metrics.sp) < 0.001)
            }
            let skyline = try #require(LayoutElementShape.shape(for: element, id: 0, xOffset: 0, metrics: metrics))
            let painted = circle.insetBy(dx: -frameLayer.lineWidth / 2, dy: -frameLayer.lineWidth / 2)
            let bounds = CGRect(x: painted.minX, y: 200 - painted.maxY, width: painted.width, height: painted.height)
            #expect(skyline.rects.contains { $0.rect.insetBy(dx: -0.001, dy: -0.001).contains(bounds) })
        }

        @Test func documentContainsAllTextAndFrames() throws {
            guard #available(macOS 15.0, *) else { return }
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .harmony(Harmony(name: "C#7", offsetY: -15)),
                .chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                    lyrics: [Lyric(text: "g")],
                )),
            ])
            let score = Score(division: 480, parts: [Part(
                id: "P1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )], systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(
                    position: .start,
                    element: .rehearsalMark(RehearsalMark(text: "A\ng", offsetY: -40, frame: .circle)),
                ),
                PositionedSystemElement(
                    position: .start,
                    element: .staffText(StaffText(text: "above\ng", offsetY: -25)),
                    originalStaff: ElementHitFixtures.anchor.staff,
                ),
                PositionedSystemElement(
                    position: .start,
                    element: .staffText(StaffText(text: "below\ng", offsetY: 40, isSystemText: true)),
                ),
            ])])
            let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 600)
            let tester = ScoreHitTester(document: document)
            let page = CGRect(origin: .zero, size: document.size).insetBy(dx: -0.001, dy: -0.001)
            var count = 0
            for system in document.systems {
                for measure in system.measures {
                    for element in measure.elements {
                        guard let id = element.textID else { continue }
                        let rect = try #require(tester.textHitRect(for: ScoreHitTarget(textID: id)))
                        #expect(page.contains(rect))
                        count += 1
                    }
                }
            }
            #expect(count == 5)
        }

        @Test func whitespaceHasNoHighlightOrClickTarget() {
            guard #available(macOS 15.0, *) else { return }
            let element = LayoutElement.staffText(
                text: " \n ", origin: ElementHitFixtures.origin, color: nil,
                style: .staffText, anchor: ElementHitFixtures.anchor,
            )
            let tester = ScoreHitTester(document: ElementHitFixtures.document([element]))
            #expect(tester.textHitRect(for: .staffText(anchor: ElementHitFixtures.anchor, style: .staffText)) == nil)
            #expect(tester.hitTest(at: CGPoint(x: 130, y: 125)) == nil)
        }

        @available(macOS 15.0, *)
        private func expectHighlightMatchesPaths(_ element: LayoutElement) throws {
            let parent = CALayer()
            var context = ScoreLayerBuilder.BuildContext()
            ScoreLayerBuilder.drawElement(
                element, base: .zero, metrics: metrics, height: 200,
                context: &context, into: parent,
            )
            let layers = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
            var expected: CGRect?
            for layer in layers {
                let path = try #require(layer.path)
                let painted = layer.fillColor != nil ? path : path.copy(
                    strokingWithWidth: layer.lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10,
                )
                let box = painted.boundingBoxOfPath
                let documentBox = CGRect(x: box.minX + 50, y: 250 - box.maxY, width: box.width, height: box.height)
                expected = expected.map { $0.union(documentBox) } ?? documentBox
            }
            let want = try #require(expected)
            let tester = ScoreHitTester(document: ElementHitFixtures.document([element]))
            let target = try ScoreHitTarget(textID: #require(element.textID))
            let got = try #require(tester.textHitRect(for: target))
            #expect(abs(got.minX - want.minX) < 0.001)
            #expect(abs(got.minY - want.minY) < 0.001)
            #expect(abs(got.maxX - want.maxX) < 0.001)
            #expect(abs(got.maxY - want.maxY) < 0.001)
        }
    }
#endif
