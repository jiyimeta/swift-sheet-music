#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    @testable import SheetMusicLayout
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
            func width(_ text: String, _ entry: LayoutFrameText) -> Double {
                Double(FontMetrics.provider.typographicWidth(
                    text: text,
                    font: LayoutFont(face: "Edwin", pointSize: entry.fontSize),
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
                honorLayoutBreaks: 0,
                collapseMultiMeasureRests: 0,
                showsInvisibleElements: 0,
                hiddenStaves: [],
                clefOverrides: [],
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
    }
#endif
