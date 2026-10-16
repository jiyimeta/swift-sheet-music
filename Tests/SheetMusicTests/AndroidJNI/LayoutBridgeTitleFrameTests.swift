#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import SheetMusicMSCX
    import Testing

    /// The Android draw-command bridge must engrave the leading `<VBox>` title
    /// block — title / subtitle / composer / lyricist — that the Apple renderer
    /// draws via `TitleFrameView`. Before this fix `buildCommands` walked only
    /// `layout.systems`; `layout.titleFrame` was silently dropped, so Android
    /// reserved the vertical space (systems were shifted down) but painted
    /// nothing in it — a blank gap at the top of the score.
    struct LayoutBridgeTitleFrameTests {
        private let _installApple = TestSupport.installApple

        private static let ptToMM = 25.4 / 72.0
        private static let availableWidth: CGFloat = 1200

        private static func titledScore() -> Score {
            let measure = Measure(
                voices: [Voice(elements: [.rest(duration: .measure)])],
            )
            let frame = ScoreFrame(heightSp: 12, texts: [
                FrameText(style: .title, text: "My Title"),
                FrameText(style: .composer, text: "A. Composer"),
                FrameText(style: .lyricist, text: "Words"),
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

        private static func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(includeTitleFrame: true),
                availableWidth: availableWidth,
            )
        }

        private static func approxEq(
            _ a: Double, _ b: Double, eps: Double = 0.05,
        ) -> Bool {
            abs(a - b) < eps
        }

        /// First `.text` command whose string matches `s`, with its (x, y).
        private static func textCommand(
            _ s: String, in commands: [DrawCommand],
        ) -> (x: Double, y: Double)? {
            for cmd in commands {
                if case let .text(text, x, y, _, _) = cmd, text == s {
                    return (x, y)
                }
            }
            return nil
        }

        @Test("title / composer / lyricist all emit text commands")
        func emitsTitleBlockText() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.layout(Self.titledScore())
            let commands = LayoutBridge.buildCommands(layout: doc)

            #expect(Self.textCommand("My Title", in: commands) != nil)
            #expect(Self.textCommand("A. Composer", in: commands) != nil)
            #expect(Self.textCommand("Words", in: commands) != nil)
        }

        @Test("horizontal anchor is resolved per entry (leading / center / trailing)")
        func resolvesHorizontalAnchor() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.layout(Self.titledScore())
            let commands = LayoutBridge.buildCommands(layout: doc)
            let frame = try #require(doc.titleFrame)

            func entry(_ style: FrameText.Style) throws -> LayoutFrameText {
                try #require(frame.texts.first { $0.style == style })
            }
            /// Measured in the face the bridge anchors with: the title block's own, as the installed provider
            /// resolves it (the system face on the Apple provider this suite installs).
            func width(_ text: String, _ entry: LayoutFrameText) -> Double {
                Double(FontMetrics.provider.typographicWidth(
                    text: text,
                    font: FontMetrics.provider.renderingTextFont(LayoutTitleFrame.font(size: entry.fontSize)),
                ))
            }

            // Lyricist defaults to bottom-LEADING: left edge sits at position.x.
            let lyricist = try entry(.lyricist)
            let lyricistCmd = try #require(Self.textCommand("Words", in: commands))
            #expect(Self.approxEq(
                lyricistCmd.x, Double(lyricist.position.x) * Self.ptToMM,
            ))

            // Title defaults to top-CENTER: left edge = position.x − width/2.
            let title = try entry(.title)
            let titleCmd = try #require(Self.textCommand("My Title", in: commands))
            let expTitleX = (
                Double(title.position.x)
                    - width("My Title", title) / 2,
            ) * Self.ptToMM
            #expect(Self.approxEq(titleCmd.x, expTitleX))

            // Composer defaults to bottom-TRAILING: left edge = position.x − width.
            let composer = try entry(.composer)
            let composerCmd = try #require(
                Self.textCommand("A. Composer", in: commands),
            )
            let expComposerX = (
                Double(composer.position.x)
                    - width("A. Composer", composer),
            ) * Self.ptToMM
            #expect(Self.approxEq(composerCmd.x, expComposerX))
        }

        @Test("page mode keeps the title block on the first page")
        func pageModeFirstPageCarriesTitle() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // layoutMode 2 == .page (see LayoutOptionsWireTests).
            let wire = LayoutOptionsWire(
                layoutMode: 2,
                staffSize: 12.0,
                collapseMultiMeasureRests: 0,
                showsInvisibleElements: 0,
                hiddenStaves: [],
                clefOverrides: [],
                transposeSemitones: 0,
                showsLyrics: 1,
                breakPolicyRaw: 3, // .ignoreAll
            )
            let options = try LayoutOptionsCodec.decode(wire.encodeToData())
            #expect(options.mode == .page)

            let result = LayoutBridge.computeWithDocument(
                score: Self.titledScore(),
                pageWidthMM: 210, pageHeightMM: 297,
                options: options,
            )
            let pages = try DrawProgramCodec.decode(result.encoded)
            let firstPage = try #require(pages.first)
            #expect(Self.textCommand("My Title", in: firstPage.commands) != nil)
        }

        @Test("a rich title line emits its runs with their own style")
        func richTitleRuns() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let markup = PreservedTextMarkup(
                content: [.element(.init(name: "b", content: [.characters("Big")])), .characters(" Title")],
                derivedText: "Big Title",
            )
            let measure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
            let score = Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [measure])])],
                systemMeasures: [SystemMeasure()],
                titleFrame: ScoreFrame(heightSp: 12, texts: [
                    FrameText(style: .title, text: "Big Title", preservedTextMarkup: markup),
                ]),
            )
            let commands = LayoutBridge.buildCommands(layout: Self.layout(score))
            var style = DrawCommand.TextStyleFlag.none
            var texts: [(String, UInt8)] = []
            for command in commands {
                if case let .setTextStyle(flags) = command { style = flags }
                if case let .text(text, _, _, _, _) = command { texts.append((text, style)) }
            }
            #expect(texts.contains { $0.0 == "Big" && $0.1 & DrawCommand.TextStyleFlag.bold != 0 })
            #expect(texts.contains { $0.0 == " Title" && $0.1 & DrawCommand.TextStyleFlag.bold == 0 })
            #expect(Self.textCommand("Big Title", in: commands) == nil)
        }

        /// A two-line rich title whose second line is set larger. Its baseline is where layout's `placedLines()`
        /// puts it (one of that line's OWN ascents below its top), which is lower than the plain twin's second
        /// line, whose baseline is one ascent of the block's face below the same top.
        @Test("a larger second title line is emitted where layout placed it, not where a plain line would sit")
        func richTitleSecondLineFollowsPlacement() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let markup = PreservedTextMarkup(
                content: [
                    .characters("Top"), .element(.init(name: "br")),
                    .element(.init(name: "font", attributes: ["size": "60"])), .characters("Big"),
                ],
                derivedText: "Top\nBig",
            )
            func score(_ entry: FrameText) -> Score {
                let measure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
                return Score(
                    division: 480,
                    parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [measure])])],
                    systemMeasures: [SystemMeasure()],
                    titleFrame: ScoreFrame(heightSp: 12, texts: [entry]),
                )
            }
            let richEntry = FrameText(style: .title, text: "Top\nBig", preservedTextMarkup: markup)
            let richDocument = Self.layout(score(richEntry))
            let frame = try #require(richDocument.titleFrame)
            let second = try #require(frame.placedLines().first { $0.entryIndex == 0 && $0.lineIndex == 1 })
            let run = try #require(second.positionedRuns.first)
            let expectedY = Double(run.baseline.y) * Self.ptToMM

            let richCommands = LayoutBridge.buildCommands(layout: richDocument)
            let richY = try #require(Self.textCommand("Big", in: richCommands)).y
            #expect(Self.approxEq(richY, expectedY, eps: 0.001))

            let plainDocument = Self.layout(score(FrameText(style: .title, text: "Top\nBig")))
            let plainY = try #require(Self.textCommand("Big", in: LayoutBridge.buildCommands(layout: plainDocument))).y
            // 60 pt against the title's own size: the larger ascent alone moves the baseline by several millimetres.
            #expect(richY - plainY > 1)
        }

        // MARK: - Frames (draw program v9)

        /// A `drawImage` as emitted, or as expected: its bytes and its rectangle in millimetres.
        private struct DrawnImage {
            var data: Data
            var x: Double
            var y: Double
            var w: Double
            var h: Double

            func matches(_ other: DrawnImage) -> Bool {
                data == other.data && abs(x - other.x) < 1e-6 && abs(y - other.y) < 1e-6
                    && abs(w - other.w) < 1e-6 && abs(h - other.h) < 1e-6
            }
        }

        /// Every `drawImage` of `commands`, in order.
        private static func images(in commands: [DrawCommand]) -> [DrawnImage] {
            commands.compactMap { command in
                guard case let .drawImage(data, x, y, w, h) = command else { return nil }
                return DrawnImage(data: data, x: x, y: y, w: w, h: h)
            }
        }

        /// The `drawImage` a laid-out picture becomes: its rectangle in millimetres, `originY` (the owning frame's top;
        /// 0 for the title's pictures, which are in document coordinates) added to its y.
        private static func expectedImage(_ image: LayoutFrameImage, originY: CGFloat) -> DrawnImage {
            DrawnImage(
                data: image.data,
                x: Double(image.rect.minX) * ptToMM,
                y: (Double(originY) + Double(image.rect.minY)) * ptToMM,
                w: Double(image.rect.width) * ptToMM,
                h: Double(image.rect.height) * ptToMM,
            )
        }

        /// The title block (with a PNG), two bars, a VBox with a JPEG, two bars.
        private static func picturesScore() throws -> Score {
            try MSCZReader.parse(MSCXFixtureLoader.msczData("frames-pictures"))
        }

        /// The title "Frames", then VBox "Part II" before bar 4, TBox "Interlude" before bar 8, VBox "End" at the end.
        private static func boxesScore() throws -> Score {
            try MSCXParser.parse(MSCXFixtureLoader.mscxData("frames-boxes"))
        }

        /// frames-pictures for the pictures (its boxes carry no text), frames-boxes for the texts (it has no picture).
        @Test("frames draw their pictures where layout put them, the title's first, and their texts inside the box")
        func framesEmitTextAndImages() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let document = try Self.layout(Self.picturesScore())
            let titlePicture = try #require(document.titleImages.first)
            let frame = try #require(document.frames.first)
            let framePicture = try #require(frame.images.first)
            let drawn = Self.images(in: LayoutBridge.buildCommands(layout: document))
            try #require(drawn.count >= 2, "\(drawn.count) pictures drawn")
            let wanted = [
                Self.expectedImage(titlePicture, originY: 0), Self.expectedImage(framePicture, originY: frame.originY),
            ]
            for (image, want) in zip(drawn, wanted) {
                #expect(image.matches(want), "drawn \(image.x), \(image.y), \(image.w), \(image.h)")
            }
            #expect(drawn[1].y > drawn[0].y)
            try Self.expectFrameTextsInTheirBoxes(Self.layout(Self.boxesScore()))
        }

        /// Every text of every frame is drawn, at a y inside its box: the frame's top added to the frame-local y the
        /// title builder gives it (a text drawn at the frame-local y would sit near the top of the page).
        private static func expectFrameTextsInTheirBoxes(_ document: LayoutDocument) throws {
            let commands = LayoutBridge.buildCommands(layout: document)
            let texts = document.frames.flatMap(\.content.texts)
            try #require(texts.count == 3, "\(texts.map(\.text))")
            for frame in document.frames {
                for entry in frame.content.texts {
                    let drawn = textCommand(entry.text, in: commands)
                    let point = try #require(drawn, "\(entry.text) is not drawn")
                    #expect(point.y >= Double(frame.originY) * ptToMM, "\(entry.text) above its box")
                    let lowest = (Double(frame.bottom) + Double(entry.fontSize)) * ptToMM
                    #expect(point.y <= lowest, "\(entry.text) below its box")
                }
            }
        }

        @Test("a frame's commands sit between the system above it and the system below it, in a span of their own")
        func framesInterleaveWithSystems() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let document = try Self.layout(Self.boxesScore())
            let spans = LayoutBridge.buildCommandsWithSpans(layout: document).spans
            let frameSpans = spans.dropFirst(document.titleFrame == nil ? 0 : 1).filter { $0.systemIndex == nil }
            try #require(document.frames.count == 3)
            try #require(frameSpans.count == document.frames.count, "\(frameSpans.count) frame spans")
            for (frame, span) in zip(document.frames, frameSpans) {
                let below = document.systemIndex(below: frame)
                let aboveIndex = (below ?? document.systems.count) - 1
                let above = spans.first { $0.systemIndex == aboveIndex }
                let aboveSpan = try #require(above, "no span for system \(aboveIndex)")
                #expect(span.commandRange.lowerBound >= aboveSpan.commandRange.upperBound)
                if let below {
                    let next = spans.first { $0.systemIndex == below }
                    let nextSpan = try #require(next, "no span for system \(below)")
                    #expect(span.commandRange.upperBound <= nextSpan.commandRange.lowerBound)
                }
                // The span's frame holds the box.
                #expect(span.frameMM.y <= Double(frame.originY) * Self.ptToMM + 1e-6)
                #expect(span.frameMM.maxY >= Double(frame.bottom) * Self.ptToMM - 1e-6)
            }
        }

        @Test("a picture no reader can decode emits no drawImage, and its box still lays out")
        func undecodablePictureEmitsNoImage() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let rest = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
            let box = ScoreFrame(heightSp: 6, texts: [], images: [FrameImage(path: "s.svg"), FrameImage(path: "j.png")])
            let title = ScoreFrame(
                heightSp: 10, texts: [FrameText(style: .title, text: "Song")], images: [FrameImage(path: "t.png")],
            )
            let score = Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [rest, rest])])],
                systemMeasures: [SystemMeasure(), SystemMeasure()],
                titleFrame: title,
                blocks: [PositionedScoreBlock(beforeMeasureIndex: 1, block: .verticalFrame(box))],
                pictures: [
                    "s.svg": Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8),
                    "j.png": Data([1, 2, 3, 4, 5, 6, 7]),
                    // A PNG cut off inside its signature.
                    "t.png": Data([0x89, 0x50, 0x4E, 0x47]),
                ],
            )
            let document = Self.layout(score)
            #expect(document.frames.count == 1)
            #expect(document.titleImages.isEmpty)
            #expect(Self.images(in: LayoutBridge.buildCommands(layout: document)).isEmpty)
        }

        @Test("a title-only score's spans are the title's, then one per system, as before frames existed")
        func titleOnlyScoreEmitsNoFrameSpans() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let document = Self.layout(Self.titledScore())
            let spans = LayoutBridge.buildCommandsWithSpans(layout: document).spans
            let expected: [Int?] = [nil] + document.systems.indices.map(Optional.some)
            #expect(document.frames.isEmpty)
            #expect(spans.map(\.systemIndex) == expected)
        }
    }
#endif
