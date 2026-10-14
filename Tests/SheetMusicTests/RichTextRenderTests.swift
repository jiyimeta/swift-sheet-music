#if os(macOS)
    import CoreGraphics
    import QuartzCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import SwiftUI
    import Testing

    /// Both Apple renderers draw a formatted text from the runs layout placed, so a symbol inside a staff text is a
    /// glyph on the page and the drawn ink is where layout measured it.
    @Suite("Rich text reaches the Apple renderers", .serialized)
    @MainActor
    struct RichTextRenderTests {
        private let _installApple = TestSupport.installApple

        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        /// "senza " and the keyboard-pedal glyph — what a plain renderer cannot draw at all.
        private static let senzaPed = StaffText(
            text: "senza ",
            preservedTextMarkup: PreservedTextMarkup(
                content: [
                    .characters("senza "),
                    .element(.init(name: "sym", content: [.characters("keyboardPedalPed")])),
                ],
                derivedText: "senza ",
            ),
        )

        private static func score(_ element: SystemElement) -> Score {
            let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
            return Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
            )], systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: element, originalStaff: staff),
            ])])
        }

        @available(macOS 15.0, *)
        private static func document(_ text: StaffText) -> LayoutDocument {
            document(lane: .staffText(text))
        }

        @available(macOS 15.0, *)
        private static func document(lane element: SystemElement) -> LayoutDocument {
            _ = BravuraFont.register
            return LayoutEngine.layout(score: score(element), options: ScoreViewOptions(), availableWidth: 800)
        }

        private static func staffText(in document: LayoutDocument) throws -> LayoutElement {
            try #require(document.systems.flatMap(\.measures).flatMap(\.elements).first { element in
                if case .staffText = element { true } else { false }
            })
        }

        @available(macOS 15.0, *)
        private static func layerWidth(_ document: LayoutDocument) throws -> CGFloat {
            let system = try #require(document.systems.first)
            let item = try #require(staffText(in: document).textItemID)
            let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: document.metrics)
            let layers = try #require(built.items[item])
            return layers.compactMap { $0.path?.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }.width
        }

        @available(macOS 15.0, *)
        @Test("the CALayer staff text draws the symbol run, where layout measured the ink")
        func layerDrawsRuns() throws {
            let rich = Self.document(Self.senzaPed)
            let richWidth = try Self.layerWidth(rich)
            #expect(try richWidth > Self.layerWidth(Self.document(StaffText(text: "senza "))) + 4)
            try Self.expectDrawnInk(Self.staffText(in: rich), metrics: rich.metrics)
        }

        /// What `drawElement` puts on a layer for `element` at `base: .zero`, as the Y-down box of its filled layers
        /// (frames are strokes and do not count). `flipForPlatform` mirrors a macOS path about `height`, so undo it.
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

        /// The drawn layer's whole box is layout's ink rect for the element, edge for edge.
        @available(macOS 15.0, *)
        private static func expectDrawnInk(_ element: LayoutElement, metrics: StaffMetrics) throws {
            let ink = try #require(TextInkGeometry.rects(for: element, metrics: metrics)?.first)
            let drawn = try drawnBox(element, metrics: metrics)
            #expect(abs(drawn.minX - ink.minX) < 0.5)
            #expect(abs(drawn.minY - ink.minY) < 0.5)
            #expect(abs(drawn.width - ink.width) < 0.5)
            #expect(abs(drawn.height - ink.height) < 0.5)
        }

        private static func isTextMarker(_ element: LayoutElement) -> Bool {
            guard case let .marker(kind, text, _, _, .some) = element else { return false }
            if case .text = MarkerGlyph.variant(for: kind, text: text) { return true }
            return false
        }

        /// The first element of the `rich-text` fixture `match` accepts, with the document's metrics.
        @available(macOS 15.0, *)
        private static func fixtureElement(
            _ match: (LayoutElement) -> Bool,
        ) throws -> (element: LayoutElement, metrics: StaffMetrics) {
            _ = BravuraFont.register
            let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("rich-text"))
            let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 1200)
            let all = document.systems.flatMap(\.measures).flatMap { $0.elements + $0.markers + $0.jumps }
            let found = all.first(where: match)
            let element = try #require(found)
            return (element, document.metrics)
        }

        @available(macOS 15.0, *)
        @Test("the CALayer lyric draws its runs where layout measured the ink")
        func lyricLayerMatchesInk() throws {
            let found = try Self.fixtureElement { element in
                if case .textMark(.lyrics, _, _, .some) = element { true } else { false }
            }
            try Self.expectDrawnInk(found.element, metrics: found.metrics)
        }

        @available(macOS 15.0, *)
        @Test("the CALayer rehearsal mark draws its runs where layout measured the ink")
        func rehearsalMarkLayerMatchesInk() throws {
            let found = try Self.fixtureElement { element in
                if case .rehearsalMark(_, _, _, _, _, _, _, .some) = element { true } else { false }
            }
            try Self.expectDrawnInk(found.element, metrics: found.metrics)
        }

        @available(macOS 15.0, *)
        @Test("the CALayer text marker draws its runs where layout measured the ink")
        func markerLayerMatchesInk() throws {
            let found = try Self.fixtureElement(Self.isTextMarker)
            try Self.expectDrawnInk(found.element, metrics: found.metrics)
        }

        @available(macOS 15.0, *)
        @Test("the CALayer jump draws its runs where layout measured the ink")
        func jumpLayerMatchesInk() throws {
            let found = try Self.fixtureElement { element in
                if case .jump(_, _, _, .some) = element { true } else { false }
            }
            try Self.expectDrawnInk(found.element, metrics: found.metrics)
        }

        /// The two model elements that print as staff text: their runs reach the layer as a staff text's do.
        @available(macOS 15.0, *)
        @Test("the CALayer swing marking and instrument change draw their runs where layout measured the ink")
        func swingAndInstrumentChangeLayersMatchInk() throws {
            let lanes: [SystemElement] = [
                .swing(Swing(text: "Swing ", preservedTextMarkup: RichTextElementKindTests.swingMarkup)),
                .instrumentChange(InstrumentChange(
                    text: "To Flute", preservedTextMarkup: RichTextElementKindTests.changeMarkup,
                )),
            ]
            for lane in lanes {
                let document = Self.document(lane: lane)
                let element = try Self.staffText(in: document)
                let carriesRuns = if case .staffText(_, _, _, _, _, _, _, _, .some) = element { true } else { false }
                #expect(carriesRuns, "\(lane) laid out without its runs")
                try Self.expectDrawnInk(element, metrics: document.metrics)
            }
        }

        @available(macOS 15.0, *)
        private static func canvasInkWidth(_ document: LayoutDocument) throws -> Int {
            let element = try staffText(in: document)
            let metrics = document.metrics
            let view = Canvas { context, _ in
                ScoreCanvasDrawing.drawElement(element, base: CGPoint(x: 150, y: 180), metrics: metrics, into: &context)
            }
            .frame(width: 700, height: 320)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return try inkWidth(#require(renderer.cgImage))
        }

        private static func inkWidth(_ image: CGImage) throws -> Int {
            let width = image.width
            let height = image.height
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
            var minX = width
            var maxX = -1
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let offset = (y * width + x) * 4
                    guard bytes[offset] < 200 || bytes[offset + 1] < 200 || bytes[offset + 2] < 200 else { continue }
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
            return maxX >= minX ? maxX - minX + 1 : 0
        }

        @available(macOS 15.0, *)
        @Test("the Canvas staff text draws the symbol run too")
        func canvasDrawsRuns() throws {
            let rich = try Self.canvasInkWidth(Self.document(Self.senzaPed))
            let plain = try Self.canvasInkWidth(Self.document(StaffText(text: "senza ")))
            #expect(rich > plain + 4)
        }

        @available(macOS 15.0, *)
        @Test("a decoration is a filled bar exactly where layout put it")
        func decorationBar() throws {
            let bar = LayoutRichTextDecoration(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 20), thickness: 2)
            let path = try #require(ScoreLayerBuilder.richTextPath(runs: [], decorations: [bar]))
            #expect(path.boundingBoxOfPath == CGRect(x: 10, y: 19, width: 30, height: 2))
        }

        /// Non-zero-winding coverage of `path` (the rule `CAShapeLayer` and `GraphicsContext.fill` use) on a
        /// `size` × `size` bitmap, Y-down: index `y * size + x` is pixel (x, y) of the path's own coordinates.
        private static func coverage(of path: CGPath, size: Int) throws -> [Bool] {
            let context = try #require(CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
            ))
            context.setShouldAntialias(false)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.translateBy(x: 0, y: CGFloat(size))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(path)
            context.fillPath()
            let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: size * size)
            return (0 ..< size * size).map { bytes[$0] > 127 }
        }

        @available(macOS 15.0, *)
        @Test("a strike bar and a glyph fill as a union, whichever way the glyph's contour winds")
        func strikeBarLeavesNoHoleInGlyph() throws {
            // Hiragino's outlines are PostScript (CFF): flipped to Y-down they wind opposite to `addRect`.
            let font = LayoutFont(face: "HiraginoSans-W3", pointSize: 80)
            let run = LayoutRichTextRun(
                content: .text("あ"), font: font, x: 0, advance: 80, baselineShift: 0, underline: false, strike: true,
            )
            let line = LayoutRichTextLine(runs: [run], width: 80, ascent: 70, descent: 15)
            let runs = line.positionedRuns(leftX: 10, baselineY: 90)
            let bar = try #require(line.decorations(leftX: 10, baselineY: 90).first).rect
            let size = 100
            let glyphs = try Self.coverage(
                of: #require(ScoreLayerBuilder.richTextPath(runs: runs, decorations: [])), size: size,
            )
            let struck = try Self.coverage(
                of: #require(ScoreLayerBuilder.richTextPath(runs: runs, decorations: line.decorations(
                    leftX: 10, baselineY: 90,
                ))), size: size,
            )
            // The pixels whose centers sit well inside the bar's rows and under a glyph stroke.
            var crossing = 0
            var holes = 0
            for y in Int(bar.minY.rounded(.up)) + 1 ..< Int(bar.maxY.rounded(.down)) - 1 {
                for x in Int(bar.minX) + 1 ..< Int(bar.maxX) - 1 where glyphs[y * size + x] {
                    crossing += 1
                    if !struck[y * size + x] { holes += 1 }
                }
            }
            #expect(crossing > 0)
            #expect(holes == 0)
        }
    }
#endif
