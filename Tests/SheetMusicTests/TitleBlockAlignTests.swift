#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// Coverage for `<{role}Align>` overrides on the `<VBox>` title
    /// block — the field that was missing when test-platinum.mscx
    /// rendered Lyricist text along the page's left edge instead of
    /// MuseScore's centred three-column lyric layout.
    @Suite("Title-block align overrides") struct TitleBlockAlignTests {
        private let _installApple = TestSupport.installApple

        @Test("TextAlign parses MSCX 'h,v' form")
        func parsesMscxString() {
            #expect(
                TextAlign(mscxString: "center,bottom")
                    == TextAlign(horizontal: .center, vertical: .bottom),
            )
            #expect(
                TextAlign(mscxString: "right,top")
                    == TextAlign(horizontal: .right, vertical: .top),
            )
            #expect(
                TextAlign(mscxString: "hcenter,vcenter")
                    == TextAlign(horizontal: .center, vertical: .center),
            )
            #expect(TextAlign(mscxString: "garbage") == nil)
        }

        @Test("Decoder reads <lyricistAlign> and <composerAlign>")
        func decoderReadsAlignOverrides() throws {
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Style>
                  <spatium>1.75</spatium>
                  <lyricistAlign>center,bottom</lyricistAlign>
                  <composerAlign>right,top</composerAlign>
                </Style>
                <Part id="1"><Staff id="1"/><Instrument id="x"/></Part>
                <Staff id="1"><Measure></Measure></Staff>
              </Score>
            </museScore>
            """
            let score = try MSCXParser.parse(Data(mscx.utf8))
            #expect(
                score.style.lyricistAlign
                    == TextAlign(horizontal: .center, vertical: .bottom),
            )
            #expect(
                score.style.composerAlign
                    == TextAlign(horizontal: .right, vertical: .top),
            )
            #expect(score.style.titleAlign == nil)
            #expect(score.style.subtitleAlign == nil)
        }

        @Test("Encoder emits <lyricistAlign> only when set; nil round-trips clean")
        func encoderRoundTripsAlignOverrides() throws {
            var style = ScoreStyle.museScoreDefaults
            style.lyricistAlign = TextAlign(horizontal: .center, vertical: .bottom)
            let original = Score(division: 480, style: style)

            let bytes = try MSCXEncoder.encode(original)
            let xml = try #require(String(bytes: bytes, encoding: .utf8))
            #expect(xml.contains("<lyricistAlign>center,bottom</lyricistAlign>"))
            #expect(!xml.contains("<titleAlign>"))

            let reparsed = try MSCXParser.parse(bytes)
            #expect(reparsed.style.lyricistAlign == style.lyricistAlign)
            #expect(reparsed.style.titleAlign == nil)
        }

        /// Default lyricist (LEFT, BOTTOM) anchors at x=0 with
        /// `.bottomLeading`. After overriding to (CENTER, BOTTOM), the
        /// same Lyricist text should anchor at docWidth/2 with `.bottom`.
        @Test("LayoutEngine uses lyricistAlign override for baseX/anchor")
        func layoutHonorsLyricistAlignOverride() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let frame = ScoreFrame(heightSp: 8, texts: [
                FrameText(style: .lyricist, text: "Words by"),
            ])
            let availableWidth: CGFloat = 600
            let options = ScoreViewOptions(includeTitleFrame: true)
            // Default — LEFT, BOTTOM
            let defaultDoc = LayoutEngine.layout(
                score: makeScore(frame: frame, style: .museScoreDefaults),
                options: options, availableWidth: availableWidth,
            )
            let defaultLyricist = try #require(
                defaultDoc.titleFrame?.texts.first { $0.style == .lyricist },
            )
            #expect(defaultLyricist.anchor == .bottomLeading)
            #expect(defaultLyricist.position.x == 0)

            // Override — CENTER, BOTTOM
            var overridden = ScoreStyle.museScoreDefaults
            overridden.lyricistAlign = TextAlign(
                horizontal: .center, vertical: .bottom,
            )
            let centeredDoc = LayoutEngine.layout(
                score: makeScore(frame: frame, style: overridden),
                options: options, availableWidth: availableWidth,
            )
            let centered = try #require(
                centeredDoc.titleFrame?.texts.first { $0.style == .lyricist },
            )
            #expect(centered.anchor == .bottom)
            // `buildTitleFrame` uses `availableWidth` as docWidth (the
            // ±sp right margin is added later when assembling the
            // `LayoutDocument.size`).
            #expect(centered.position.x == availableWidth / 2)
        }

        @Test("FrameText carries per-element <size>; layout honours it")
        func perTextFontSizeOverride() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Style><spatium>1.75</spatium></Style>
                <Part id="1"><Staff id="1"/><Instrument id="x"/></Part>
                <Staff id="1">
                  <VBox>
                    <height>10</height>
                    <Text>
                      <style>Lyricist</style>
                      <size>7</size>
                      <text>Verse 1</text>
                    </Text>
                  </VBox>
                  <Measure></Measure>
                </Staff>
              </Score>
            </museScore>
            """
            let score = try MSCXParser.parse(Data(mscx.utf8))
            let lyricist = try #require(
                score.titleFrame?.texts.first { $0.style == .lyricist },
            )
            #expect(lyricist.fontSize == 7)

            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(includeTitleFrame: true),
                availableWidth: 600,
            )
            let laid = try #require(
                doc.titleFrame?.texts.first { $0.style == .lyricist },
            )
            #expect(laid.fontSize == 7)
        }

        @Test("FrameText.fontSize round-trips through encoder")
        func fontSizeRoundTrip() throws {
            let frame = ScoreFrame(heightSp: 10, texts: [
                FrameText(style: .lyricist, text: "x", fontSize: 7),
            ])
            let part = Part(
                id: "p1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [])])],
            )
            let original = Score(
                division: 480, parts: [part], titleFrame: frame,
            )

            let bytes = try MSCXEncoder.encode(original)
            let xml = try #require(String(bytes: bytes, encoding: .utf8))
            #expect(xml.contains("<size>7</size>"))

            let reparsed = try MSCXParser.parse(bytes)
            #expect(reparsed.titleFrame?.texts.first?.fontSize == 7)
        }

        @Test("LayoutEngine uses composerAlign override (right,top)")
        func layoutHonorsComposerAlignOverride() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let frame = ScoreFrame(heightSp: 8, texts: [
                FrameText(style: .composer, text: "Arr."),
            ])
            var overridden = ScoreStyle.museScoreDefaults
            overridden.composerAlign = TextAlign(
                horizontal: .right, vertical: .top,
            )
            let availableWidth: CGFloat = 600
            let doc = LayoutEngine.layout(
                score: makeScore(frame: frame, style: overridden),
                options: ScoreViewOptions(includeTitleFrame: true),
                availableWidth: availableWidth,
            )
            let composer = try #require(
                doc.titleFrame?.texts.first { $0.style == .composer },
            )
            #expect(composer.anchor == .topTrailing)
            #expect(composer.position.x == availableWidth)
            #expect(composer.position.y == 0)
        }

        /// MuseScore 4 writes `<style>` values in lowercase (e.g.
        /// `<style>composer</style>`). The decoder must accept both the
        /// capitalized form (round-trip with our own encoder) and the
        /// lowercase form (real MS4 files), otherwise `composer` falls
        /// back to `.other` and the text lands at center-top instead of
        /// the `.composer` default (right, bottom).
        @Test("Decoder accepts lowercase MS4 <style> values")
        func decoderAcceptsLowercaseStyleValues() throws {
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Part id="1"><Staff id="1"/><Instrument id="x"/></Part>
                <Staff id="1">
                  <VBox>
                    <height>10</height>
                    <Text><style>title</style><text>T</text></Text>
                    <Text><style>subtitle</style><text>S</text></Text>
                    <Text><style>composer</style><text>C</text></Text>
                    <Text><style>lyricist</style><text>L</text></Text>
                  </VBox>
                  <Measure></Measure>
                </Staff>
              </Score>
            </museScore>
            """
            let score = try MSCXParser.parse(Data(mscx.utf8))
            let styles = score.titleFrame?.texts.map(\.style)
            #expect(styles == [.title, .subtitle, .composer, .lyricist])
        }

        /// MuseScore historically uses the `<style>poet</style>` tag for
        /// the lyricist role (see `engraving/types/types.h`,
        /// `TextStyleType::POET`). Files exported by MuseScore 4 use this
        /// tag, so the decoder must alias it to `.lyricist` rather than
        /// dropping to `.other`.
        @Test("Decoder maps <style>poet</style> to .lyricist")
        func decoderMapsPoetToLyricist() throws {
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Part id="1"><Staff id="1"/><Instrument id="x"/></Part>
                <Staff id="1">
                  <VBox>
                    <height>10</height>
                    <Text><style>poet</style><text>P</text></Text>
                  </VBox>
                  <Measure></Measure>
                </Staff>
              </Score>
            </museScore>
            """
            let score = try MSCXParser.parse(Data(mscx.utf8))
            #expect(score.titleFrame?.texts.first?.style == .lyricist)
        }

        /// A `<Text>` inside `<VBox>` can carry an `<align>` element that
        /// overrides the styledef default for just that element (e.g. a
        /// "lyricist" text repositioned to top-left via
        /// `<align>left,top</align>`). The layout engine must honour the
        /// per-element override; otherwise the text falls back to the
        /// role default (bottom-left for lyricist) and may overlap with
        /// other texts in the frame.
        @Test("LayoutEngine honours per-element <align> override")
        func layoutHonorsPerElementAlignOverride() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Part id="1"><Staff id="1"/><Instrument id="x"/></Part>
                <Staff id="1">
                  <VBox>
                    <height>10</height>
                    <Text>
                      <style>lyricist</style>
                      <align>left,top</align>
                      <text>Top-left</text>
                    </Text>
                  </VBox>
                  <Measure></Measure>
                </Staff>
              </Score>
            </museScore>
            """
            let score = try MSCXParser.parse(Data(mscx.utf8))
            let lyricist = try #require(score.titleFrame?.texts.first)
            #expect(
                lyricist.align == TextAlign(horizontal: .left, vertical: .top),
            )
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(includeTitleFrame: true),
                availableWidth: 600,
            )
            let laid = try #require(doc.titleFrame?.texts.first)
            #expect(laid.anchor == .topLeading)
            #expect(laid.position.x == 0)
            #expect(laid.position.y == 0)
        }

        private func makeScore(
            frame: ScoreFrame, style: ScoreStyle,
        ) -> Score {
            let part = Part(
                id: "p1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [])])],
            )
            return Score(
                division: 480, parts: [part],
                titleFrame: frame, style: style,
            )
        }
    }
#endif
