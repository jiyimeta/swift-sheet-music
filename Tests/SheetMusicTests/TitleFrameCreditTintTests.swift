#if os(macOS)
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// A selected title-block credit in the title block's layer tree, which `ScoreView` hosts through
    /// `FrameContentView`: every layer of the entry `LayoutTitleFrame.creditEntryIndex(for:)` names is filled with the
    /// selection color, the way a selected tempo text's glyphs are, and every other layer keeps the ink. Beside
    /// `TitleFrameLayerTests`, which pins the tree's geometry.
    @Suite("Title frame credit tint")
    struct TitleFrameCreditTintTests {
        private let _installApple = TestSupport.installApple

        private static let availableWidth: CGFloat = 1200

        /// Not ink, so a layer filled with it can only have come from the tint.
        private static var selectionColor: CGColor {
            CGColor(red: 0, green: 0.45, blue: 0.95, alpha: 1)
        }

        private static func titleFrame(_ texts: [FrameText]) throws -> LayoutTitleFrame {
            let measure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
            let score = Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [measure])])],
                systemMeasures: [SystemMeasure()],
                titleFrame: ScoreFrame(heightSp: 12, texts: texts),
            )
            return try #require(LayoutEngine.layout(
                score: score, options: ScoreViewOptions(includeTitleFrame: true), availableWidth: availableWidth,
            ).titleFrame)
        }

        private static func titleAndComposer() -> [FrameText] {
            [FrameText(style: .title, text: "My Title"), FrameText(style: .composer, text: "A. Composer")]
        }

        /// The block's ink layers with `credit` selected, in placed-line order.
        @available(macOS 15.0, *)
        private static func layers(_ frame: LayoutTitleFrame, credit: ScoreInfoWrite.Field?) -> [CAShapeLayer] {
            let root = TitleFrameLayerBuilder.build(
                frame: frame, images: [], width: availableWidth, height: frame.height,
                creditTint: credit.map { CreditTint(field: $0, color: selectionColor) },
            )
            return (root.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        }

        private static func inkBoxes(_ layers: [CAShapeLayer]) -> [CGRect?] {
            layers.map { $0.path?.boundingBoxOfPath }
        }

        @Test("a selected composer is filled in the selection color and the title keeps the ink")
        func aSelectedComposerTakesTheSelectionColor() throws {
            guard #available(macOS 15.0, *) else { return }
            let frame = try Self.titleFrame(Self.titleAndComposer())
            #expect(TitleFrameRenderer.placedLines(frame).map(\.text) == ["My Title", "A. Composer"])
            let layers = Self.layers(frame, credit: .composer)
            #expect(layers.map(\.fillColor) == [ScoreLayerBuilder.inkColor, Self.selectionColor])
        }

        /// With nothing selected the tree is the one the public builder has always made, all ink; the tint repaints
        /// the selected credit without moving any ink.
        @Test("nothing selected fills every layer with ink, and the tint moves no ink")
        func nothingSelectedIsAllInk() throws {
            guard #available(macOS 15.0, *) else { return }
            let frame = try Self.titleFrame(Self.titleAndComposer())
            let plain = Self.layers(frame, credit: nil)
            #expect(plain.count == 2)
            #expect(plain.allSatisfy { $0.fillColor == ScoreLayerBuilder.inkColor })

            let publicRoot = TitleFrameLayerBuilder.build(
                frame: frame, images: [], width: Self.availableWidth, height: frame.height,
            )
            let publicLayers = (publicRoot.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
            #expect(publicLayers.map(\.fillColor) == plain.map(\.fillColor))
            #expect(Self.inkBoxes(publicLayers) == Self.inkBoxes(plain))

            #expect(Self.inkBoxes(Self.layers(frame, credit: .composer)) == Self.inkBoxes(plain))
        }

        /// The rule `LayoutDocument.creditTextLine(for:)` applies: a credit with no one-line text on the block (none
        /// engraved, no title-block style, or a multi-line block) is not one a tap can select, so none is tinted.
        @Test("a credit with no one-line engraved text tints nothing")
        func aCreditWithoutAOneLineTextTintsNothing() throws {
            guard #available(macOS 15.0, *) else { return }
            let frame = try Self.titleFrame(Self.titleAndComposer())
            for credit: ScoreInfoWrite.Field in [.lyricist, .arranger] {
                let layers = Self.layers(frame, credit: credit)
                #expect(layers.count == 2)
                #expect(layers.allSatisfy { $0.fillColor == ScoreLayerBuilder.inkColor }, "\(credit)")
            }

            let multi = try Self.titleFrame([
                FrameText(style: .title, text: "My Title"),
                FrameText(style: .composer, text: "Line one\nLine two"),
            ])
            let layers = Self.layers(multi, credit: .composer)
            #expect(layers.count == 3, "control: both composer lines are drawn")
            #expect(layers.allSatisfy { $0.fillColor == ScoreLayerBuilder.inkColor })
        }

        /// A formatted line is one filled path of its runs (`ScoreLayerBuilder.richTextPath`), which takes the color
        /// as a plain line's text layer does.
        @Test("a selected formatted credit is filled in the selection color")
        func aSelectedRichCreditTakesTheSelectionColor() throws {
            guard #available(macOS 15.0, *) else { return }
            let markup = PreservedTextMarkup(
                content: [
                    .element(.init(name: "b", content: [.characters("Big")])),
                    .element(.init(name: "sym", content: [.characters("coda")])),
                ],
                derivedText: "Big",
            )
            let frame = try Self.titleFrame([FrameText(style: .title, text: "Big", preservedTextMarkup: markup)])
            #expect(frame.texts.first?.richText != nil, "control: the title is a formatted line")
            #expect(Self.layers(frame, credit: .title).map(\.fillColor) == [Self.selectionColor])
            #expect(Self.layers(frame, credit: nil).map(\.fillColor) == [ScoreLayerBuilder.inkColor])
        }
    }
#endif
