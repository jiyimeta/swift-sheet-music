#if os(macOS)
    import AppKit
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    /// The title block's CALayer tree — what `TitleFrameView` hosts.
    ///
    /// It replaced a SwiftUI `Canvas`, which rasterised once at its
    /// layout size and so went soft the moment the reader zoomed in
    /// (the systems under it had already left the `Canvas` behind for
    /// exactly that reason). What these tests pin is the part of the
    /// swap that could silently go wrong and still compile: the
    /// LayoutEngine's Y-down coordinates have to be flipped exactly
    /// once, against the frame height, or the title comes out at the
    /// bottom of the block and the composer at the top.
    @Suite("Title frame layer tree")
    struct TitleFrameLayerTests {
        private let _installApple = TestSupport.installApple

        private static let availableWidth: CGFloat = 1200

        /// Title (top-anchored) plus composer and lyricist, which
        /// MuseScore anchors to the BOTTOM of the block — so the
        /// fixture exercises both ends of the frame.
        private static func titledScore() -> Score {
            let measure = Measure(
                voices: [Voice(elements: [.rest(duration: .measure)])],
            )
            let frame = ScoreFrame(heightSp: 12, texts: [
                FrameText(style: .title, text: "My Title"),
                FrameText(style: .composer, text: "A. Composer"),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [measure])],
                )],
                systemMeasures: [SystemMeasure()],
                titleFrame: frame,
            )
        }

        private static func titleFrame() -> LayoutTitleFrame? {
            LayoutEngine.layout(
                score: titledScore(),
                options: ScoreViewOptions(includeTitleFrame: true),
                availableWidth: availableWidth,
            ).titleFrame
        }

        @Test("One ink layer per placed line")
        func oneLayerPerLine() throws {
            guard #available(macOS 15.0, *) else { return }
            let frame = try #require(Self.titleFrame())
            let expected = TitleFrameRenderer.placedLines(frame).count
            #expect(expected == 2)

            let root = TitleFrameLayerBuilder.build(
                frame: frame, width: Self.availableWidth,
            )

            #expect(root.sublayers?.count == expected)
        }

        /// The flip test. In the host layer's native Y-up space the
        /// title's ink must sit NEAR THE TOP of the block (a large
        /// `maxY`) and the bottom-anchored composer near the bottom.
        /// A missing — or doubled — flip inverts exactly this.
        @Test("The title sits above the composer in the host's Y-up space")
        func flipPutsTheTitleOnTop() throws {
            guard #available(macOS 15.0, *) else { return }
            let frame = try #require(Self.titleFrame())
            let root = TitleFrameLayerBuilder.build(
                frame: frame, width: Self.availableWidth,
            )
            let layers = try #require(root.sublayers as? [CAShapeLayer])
            let boxes = layers.compactMap { $0.path?.boundingBoxOfPath }
            #expect(boxes.count == 2)
            let title = try #require(boxes.first)
            let composer = try #require(boxes.last)

            #expect(title.minY > composer.maxY, "the title has to be above the composer")
            #expect(title.maxY <= frame.height, "the title's ink must stay inside the block")
            #expect(composer.minY >= 0, "the composer's ink must stay inside the block")
        }

        /// The horizontal anchor really is applied. Dropping it — or
        /// reading a `.top` line as leading — moves a centred string
        /// by half its own width, which nothing else here would catch
        /// because the flip only touches y.
        @Test("Each line's ink lands on its placed anchor")
        func linesLandOnTheirAnchor() throws {
            guard #available(macOS 15.0, *) else { return }
            let frame = try #require(Self.titleFrame())
            let placed = TitleFrameRenderer.placedLines(frame)
            let root = TitleFrameLayerBuilder.build(
                frame: frame, width: Self.availableWidth,
            )
            let layers = try #require(root.sublayers as? [CAShapeLayer])
            #expect(layers.count == placed.count)

            for (line, layer) in zip(placed, layers) {
                let box = try #require(layer.path?.boundingBoxOfPath)
                // `x` is not flipped, so the anchor's own arithmetic —
                // `bbox.minX + anchor.x * bbox.width` at `position.x` —
                // is readable straight off the ink box.
                let anchored = box.minX + line.anchor.x * box.width
                #expect(
                    abs(anchored - line.position.x) < 0.01,
                    "\"\(line.text)\" anchored at \(anchored), placed at \(line.position.x)",
                )
            }
            // And the check is not vacuous: MuseScore centres the
            // title and right-aligns the composer, so the fixture
            // really does exercise two different anchors rather than
            // passing because every `anchor.x` happened to be 0.
            #expect(Set(placed.map(\.anchor)) == [.top, .topTrailing])
        }

        @Test("A rich title line is filled from its runs, symbol included")
        func richTitleLine() throws {
            guard #available(macOS 15.0, *) else { return }
            func titleFrame(_ text: FrameText) throws -> LayoutTitleFrame {
                let measure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
                let score = Score(
                    division: 480,
                    parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [measure])])],
                    systemMeasures: [SystemMeasure()],
                    titleFrame: ScoreFrame(heightSp: 12, texts: [text]),
                )
                return try #require(LayoutEngine.layout(
                    score: score, options: ScoreViewOptions(includeTitleFrame: true),
                    availableWidth: Self.availableWidth,
                ).titleFrame)
            }
            func inkWidth(_ frame: LayoutTitleFrame) -> CGFloat {
                (TitleFrameLayerBuilder.build(frame: frame, width: Self.availableWidth).sublayers ?? [])
                    .compactMap { ($0 as? CAShapeLayer)?.path?.boundingBoxOfPath }
                    .reduce(CGRect.null) { $0.union($1) }.width
            }
            let markup = PreservedTextMarkup(
                content: [
                    .element(.init(name: "b", content: [.characters("Big")])),
                    .element(.init(name: "sym", content: [.characters("coda")])),
                ],
                derivedText: "Big",
            )
            let rich = try titleFrame(FrameText(style: .title, text: "Big", preservedTextMarkup: markup))
            let plain = try titleFrame(FrameText(style: .title, text: "Big"))
            #expect(inkWidth(rich) > inkWidth(plain) + 5)
        }

        // MARK: - Pictures

        /// frames-pictures laid out: a PNG in the title block, a JPEG in the box before measure 2.
        private static func picturesDocument() throws -> LayoutDocument {
            let score = try MSCZReader.parse(MSCXFixtureLoader.msczData("frames-pictures"))
            return LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: availableWidth)
        }

        /// `rect`, y down from the top of a block `height` tall, in the host layer's native Y-up space.
        private static func flipped(_ rect: CGRect, height: CGFloat) -> CGRect {
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }

        /// Equal to a thousandth of a point: a layer's `frame` is read back from its `position` and `bounds`.
        private static func closeEnough(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            let deltas = [lhs.minX - rhs.minX, lhs.minY - rhs.minY, lhs.width - rhs.width, lhs.height - rhs.height]
            let worst = deltas.map { abs($0) }.max() ?? 0
            return worst < 0.001
        }

        /// Each picture of a block is one layer holding the decoded image, stretched to its rect and flipped against
        /// the block's height exactly as the texts are. The title block's pictures are in document coordinates and a
        /// frame's are relative to the frame's top; both are the block's own space, so the two are built alike.
        @Test("A picture becomes one image layer filling its rect, flipped like the texts")
        func pictureBecomesAnImageLayer() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = try Self.picturesDocument()
            let title = try #require(doc.titleFrame)
            let frame = try #require(doc.frames.first)
            let blocks = [
                (title, doc.titleImages, title.height),
                (frame.content, frame.images, frame.height),
            ]
            for (content, images, height) in blocks {
                let picture = try #require(images.first)
                let root = TitleFrameLayerBuilder.build(
                    frame: content, images: images, width: doc.size.width, height: height,
                )
                let pictureLayers = (root.sublayers ?? []).filter { $0.contents != nil }
                #expect(pictureLayers.count == 1)
                let layer = try #require(pictureLayers.first)
                let expected = Self.flipped(picture.rect, height: height)
                #expect(Self.closeEnough(layer.frame, expected), "layer at \(layer.frame), picture at \(expected)")
                #expect(layer.contentsGravity == .resize)
                let contents = try #require(layer.contents)
                #expect(CFGetTypeID(contents as AnyObject) == CGImage.typeID)
            }
        }

        /// A score whose only box is its title block lays out no frame, and its block builds through the
        /// picture-aware builder exactly the tree `TitleFrameView(frame:width:)` has always hosted: one ink layer per
        /// placed line, in the same places, and no picture layer.
        @Test("A title-only score's block builds the same layer tree through the picture-aware builder")
        func titleOnlyViewIsUnchanged() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = LayoutEngine.layout(
                score: Self.titledScore(),
                options: ScoreViewOptions(includeTitleFrame: true),
                availableWidth: Self.availableWidth,
            )
            let frame = try #require(doc.titleFrame)
            #expect(doc.frames.isEmpty)
            #expect(doc.titleImages.isEmpty)
            let legacy = TitleFrameLayerBuilder.build(frame: frame, width: Self.availableWidth)
            let current = TitleFrameLayerBuilder.build(
                frame: frame, images: doc.titleImages, width: Self.availableWidth, height: frame.height,
            )
            let legacyLayers = legacy.sublayers ?? []
            let currentLayers = current.sublayers ?? []
            #expect(current.frame == legacy.frame)
            #expect(currentLayers.count == TitleFrameRenderer.placedLines(frame).count)
            #expect(currentLayers.count == legacyLayers.count)
            #expect(currentLayers.map(\.frame) == legacyLayers.map(\.frame))
            func inkBoxes(_ layers: [CALayer]) -> [CGRect?] {
                layers.map { ($0 as? CAShapeLayer)?.path?.boundingBoxOfPath }
            }
            #expect(inkBoxes(currentLayers) == inkBoxes(legacyLayers))
            let pictureLayerCount = currentLayers.count { $0.contents != nil }
            #expect(pictureLayerCount == 0)
        }
    }
#endif
