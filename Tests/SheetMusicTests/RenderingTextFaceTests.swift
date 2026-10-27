#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    import QuartzCore
    import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import Testing

    /// Inside a `FontMetrics.withProvider` scope whose provider draws text in other faces than asked — the portable
    /// table, which answers Edwin for every text face but Bravura — the Apple renderers draw every text in that face,
    /// so a layout the table measured is drawn in the faces it was measured in. Under CoreText nothing changes.
    @Suite("Apple text follows the scoped provider's rendering faces")
    @MainActor
    struct RenderingTextFaceTests {
        private let _installApple = TestSupport.installApple

        /// A face the table does not carry, so it measures and draws it as Edwin.
        private nonisolated static let freeSerif = TextProperties(face: "FreeSerif")

        /// One bar: a C♯ whole note, whose accidental the layer builder measures through the provider, under a staff
        /// text in a face the table does not carry, which the layer builder draws through `ResolvedTextStyle`.
        private nonisolated static let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 61, tpc: 21, accidental: .sharp)]))),
            ])])])],
        )], systemMeasures: [SystemMeasure(elements: [PositionedSystemElement(
            position: .start, element: .staffText(StaffText(text: "dolce", properties: freeSerif)),
            originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        )])])

        /// The portable table a video lays out with, as the Apple module bundles it.
        @available(macOS 15.0, *)
        private static func table() throws -> any FontMetricsProvider {
            let url = try #require(SheetMusicFonts.portableMetricsTableURL)
            return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: url)))
        }

        private nonisolated static func family(_ font: CTFont) -> String {
            CTFontCopyFamilyName(font) as String
        }

        @available(macOS 15.0, *)
        @Test("under CoreText every text site draws the font it always drew")
        func underCoreTextNothingIsSubstituted() {
            FontMetrics.withProvider(AppleFontMetricsProvider()) {
                let label = LayoutFont(face: "", pointSize: 10, weight: .semibold)
                #expect(RenderingTextFace.substitute(for: label) == nil)
                #expect(RenderingTextFace.substitute(for: LayoutFont(face: "FreeSerif", pointSize: 10)) == nil)
                let styled = ResolvedTextStyle.resolve(
                    .staffText, overrides: Self.freeSerif, metrics: StaffMetrics(staffSize: 28),
                )
                #expect(styled.face == "FreeSerif")
                #expect(Self.family(ScoreLayerBuilder.systemFont(size: 10, italic: false)) != "Edwin")
                #expect(LabelFont.substitute(size: 10, italic: true) == nil)
                #expect(Self.family(TitleFrameRenderer.ctFont(size: 20)) != "Edwin")
            }
        }

        @available(macOS 15.0, *)
        @Test("under the portable table every text face is Edwin, Bravura stays Bravura, and no Edwin stays cached")
        func underTheTableEveryTextIsEdwin() throws {
            try FontMetrics.withProvider(Self.table()) {
                let styled = ResolvedTextStyle.resolve(
                    .staffText, overrides: Self.freeSerif, metrics: StaffMetrics(staffSize: 28),
                )
                #expect(Self.family(styled.ctFont) == "Edwin")
                #expect(Self.family(ScoreLayerBuilder.systemFont(size: 10, italic: false)) == "Edwin")
                #expect(LabelFont.substitute(size: 10, italic: true).map(Self.family) == "Edwin")
                #expect(Self.family(TitleFrameRenderer.ctFont(size: 20)) == "Edwin")
                #expect(RenderingTextFace.substitute(for: LayoutFont(face: SMuFLFamily.bravura, pointSize: 20)) == nil)
            }
            // `systemFont` caches one font; a scope's substitute must not be what the next caller outside it gets.
            #expect(Self.family(ScoreLayerBuilder.systemFont(size: 10, italic: false)) != "Edwin")
        }

        /// It passes on a correct scope; its job is to catch a renderer that drops the task-local: a layer build moved
        /// to another thread or a detached task would draw with the process-wide provider.
        @available(macOS 15.0, *)
        @Test("building a system's layers inside a scope reads the scope's provider")
        func layerDrawingUnderTheScopeReadsTheScope() throws {
            let table = try Self.table()
            let document = FontMetrics.withProvider(table) {
                LayoutEngine.layout(score: Self.score, options: ScoreViewOptions(), availableWidth: 500)
            }
            let system = try #require(document.systems.first)
            let counting = CountingFontMetricsProvider(base: table)
            FontMetrics.withProvider(counting) {
                _ = ScoreLayerBuilder.buildSystem(system, metrics: document.metrics)
            }
            #expect(counting.reads > 0)
        }

        /// Asserted on what was drawn, not on the font resolution that feeds it: a layer builder that resolved the
        /// substitute and then drew the author's face fails here.
        @available(macOS 15.0, *)
        @Test("a staff text the table measured is drawn in Edwin by the layer builder")
        func theLayerStaffTextIsDrawnInEdwin() throws {
            let table = try Self.table()
            let document = FontMetrics.withProvider(table) {
                LayoutEngine.layout(score: Self.score, options: ScoreViewOptions(), availableWidth: 500)
            }
            let system = try #require(document.systems.first)
            let element = try #require(system.measures.flatMap(\.elements).first { $0.textItemID != nil })
            guard case let .staffText(text, _, _, style, _, _, properties, _, _) = element else {
                Issue.record("the score's one text is not a plain staff text: \(element)")
                return
            }
            let item = try #require(element.textItemID)
            let built = FontMetrics.withProvider(table) {
                ScoreLayerBuilder.buildSystemWithItems(system, metrics: document.metrics)
            }
            let drawn = try #require(built.items[item])
                .compactMap { $0.path?.boundingBoxOfPath }
                .reduce(CGRect.null) { $0.union($1) }

            let size = ResolvedTextStyle.resolve(style, overrides: properties, metrics: document.metrics).pointSize
            let edwin = try #require(
                ScoreLayerBuilder.textPath(text, font: CTFontCreateWithName("Edwin" as CFString, size, nil)),
            ).boundingBoxOfPath
            #expect(abs(drawn.width - edwin.width) < 0.01, "drawn \(drawn.width) pt wide, Edwin sets it \(edwin.width)")
        }

        /// A one-bar score under a one-line title block.
        private nonisolated static let titled = Score(
            division: 480,
            parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [.rest(duration: .measure)])])])],
            )],
            systemMeasures: [SystemMeasure()],
            titleFrame: ScoreFrame(heightSp: 12, texts: [FrameText(style: .title, text: "Sonatina")]),
        )

        /// The width of the ink a title block's layer tree holds.
        private static func inkWidth(_ root: CALayer) -> CGFloat {
            (root.sublayers ?? [])
                .compactMap { ($0 as? CAShapeLayer)?.path?.boundingBoxOfPath }
                .reduce(CGRect.null) { $0.union($1) }.width
        }

        /// What a host drawing a title block inside the scope gets (a video frame of the page's top): the builder
        /// resolves every outline when it is called, so the tree it returns holds Edwin's paths after the scope has
        /// ended. Built under CoreText from the same layout, the title is set in another face — so the scope, not the
        /// layout, is what chose Edwin.
        @available(macOS 15.0, *)
        @Test("a title block built inside the scope is drawn in Edwin, and keeps it after the scope ends")
        func theTitleBlockBuiltInTheScopeIsDrawnInEdwin() throws {
            let table = try Self.table()
            let document = FontMetrics.withProvider(table) {
                LayoutEngine.layout(
                    score: Self.titled, options: ScoreViewOptions(includeTitleFrame: true), availableWidth: 500,
                )
            }
            let frame = try #require(document.titleFrame)
            func build() -> CALayer {
                TitleFrameLayerBuilder.build(
                    frame: frame, images: document.titleImages, width: document.size.width, height: frame.height,
                )
            }
            let scoped = FontMetrics.withProvider(table) { build() }
            let underCoreText = FontMetrics.withProvider(AppleFontMetricsProvider()) { build() }

            let line = try #require(TitleFrameRenderer.placedLines(frame).first)
            let edwinFont = CTFontCreateWithName("Edwin" as CFString, line.fontSize, nil)
            let edwin = try #require(ScoreLayerBuilder.textPath(line.text, font: edwinFont)).boundingBoxOfPath
            let drawn = Self.inkWidth(scoped)
            #expect(abs(drawn - edwin.width) < 0.01, "drawn \(drawn) pt wide, Edwin sets it \(edwin.width)")
            let system = Self.inkWidth(underCoreText)
            #expect(abs(system - edwin.width) > 0.5, "CoreText set the title \(system) pt wide, as Edwin would")
        }
    }
#endif
