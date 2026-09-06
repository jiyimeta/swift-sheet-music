#if os(macOS)
    import AppKit
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
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
    }
#endif
