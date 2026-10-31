#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// `PDFImportOptions.omrTextRecognizer` reaching a raster page: the recognizer's lines become the page's texts, the
    /// walker's own texts on that page are dropped, and a recognizer that is not set changes nothing.
    struct PDFImporterRasterOCRTests {
        private typealias Fixtures = PDFImporterRasterFallbackTests

        // MARK: - Tests

        @Test func noRecognizerLeavesARasterPageWithoutText() throws {
            let run = try Self.fallback(Fixtures.imageOnlyPDF(Fixtures.staffBitmap()), recognizer: nil)
            #expect(run.rasterPages == [0], "the page must be read as raster, or nothing below is measured")
            #expect(run.content.texts.filter { $0.pageIndex == 0 }.isEmpty)
        }

        @Test func aRecognizerFillsTheRasterPagesTexts() throws {
            let recognizer = FakeTextRecognizer { index, _ in index == 0 ? [Self.line("あ")] : [] }
            let run = try Self.fallback(Fixtures.imageOnlyPDF(Fixtures.staffBitmap()), recognizer: recognizer)
            #expect(run.rasterPages == [0])
            let texts = run.content.texts.filter { $0.pageIndex == 0 }
            #expect(texts.count == 1)
            let glyph = try #require(texts.first)
            #expect(glyph.text == "あ")
            #expect(glyph.ocr != nil)
            let size = try #require(run.pageSizes[0])
            #expect(glyph.origin.x >= 0 && glyph.origin.x <= size.width)
            #expect(glyph.origin.y >= 0 && glyph.origin.y <= size.height)
        }

        @Test func theRecognizerSeesTheDeskewedBitmap() throws {
            var analysis = RasterPage.analyze(Fixtures.staffBitmap(), pageIndex: 0, keepDeskewed: true)
            let source = try #require(analysis.deskewed)
            let uniform = GrayBitmap(
                pixels: [UInt8](repeating: 0x80, count: source.width * source.height),
                width: source.width, height: source.height, dpi: source.dpi,
            )
            analysis.deskewed = uniform

            let recognizer = FakeTextRecognizer()
            _ = try RasterFrontEnd.assembled(
                analysis: analysis, pageIndex: 0, detector: Fixtures.Tripwire(),
                textRecognizer: recognizer, diagnostics: nil,
            )
            let first = try #require(recognizer.images.first)
            #expect(first.width == uniform.width * 2)
            #expect(!recognizer.images.isEmpty)
            for image in recognizer.images {
                #expect(image.pixels.allSatisfy { $0 == 0x80 })
            }
        }

        @Test func aRasterPageDropsTheWalkersTexts() throws {
            let data = try Self.imageWithVectorTextPDF()
            let walked = try PDFImporter.walkDocument(PDFImporter.openDocument(data))
            #expect(
                walked.content.texts.contains { $0.pageIndex == 0 && $0.ocr == nil },
                "the fixture's vector text must reach the walker, or the drop below is not measured",
            )

            let recognizer = FakeTextRecognizer { index, _ in index == 0 ? [Self.line("あ")] : [] }
            let run = try Self.fallback(data, recognizer: recognizer)
            #expect(run.rasterPages == [0])
            let page = run.content.texts.filter { $0.pageIndex == 0 }
            #expect(page.allSatisfy { $0.ocr != nil }, "no walker glyph may survive on a raster page")
            #expect(!page.isEmpty)

            // Without a recognizer the walker's texts are exactly what they were.
            let untouched = try Self.fallback(data, recognizer: nil)
            #expect(untouched.content.texts.contains { $0.pageIndex == 0 && $0.ocr == nil })
        }

        @Test(.enabled(if: Fixtures.bravuraAvailable))
        func aVectorPageKeepsItsTexts() throws {
            let data = try Self.vectorTextThenImagePDF()
            let walked = try PDFImporter.walkDocument(PDFImporter.openDocument(data))
            let before = walked.content.texts.filter { $0.pageIndex == 0 }
            #expect(!before.isEmpty, "the vector page must carry walker text, or this passes blind")

            let recognizer = FakeTextRecognizer { index, _ in index == 0 ? [Self.line("あ")] : [] }
            let run = try Self.fallback(data, recognizer: recognizer)
            #expect(run.rasterPages == [1])
            let after = run.content.texts.filter { $0.pageIndex == 0 }
            #expect(after.map(\.text) == before.map(\.text))
            #expect(after.map(\.origin) == before.map(\.origin))
            #expect(after.allSatisfy { $0.ocr == nil })
            #expect(run.content.texts.contains { $0.pageIndex == 1 && $0.ocr != nil })
        }

        @Test func aFailingRecognizerKeepsThePagesNotes() throws {
            let data = try Fixtures.imageOnlyPDF(Fixtures.staffBitmap())
            let baseline = try Self.fallback(data, recognizer: nil)

            let log = Fixtures.DiagnosticLog()
            let failing = FakeTextRecognizer { index, _ in throw Fixtures.FixtureError.detectorFailed(index) }
            let run = try Self.fallback(data, recognizer: failing, log: log)
            #expect(run.rasterPages == baseline.rasterPages)
            #expect(run.content.glyphs.count == baseline.content.glyphs.count)
            #expect(run.content.paths.count == baseline.content.paths.count)
            #expect(run.content.texts.filter { $0.pageIndex == 0 }.isEmpty)
            #expect(log.messages.contains { $0.contains("OCR") })
        }

        // MARK: - Helpers

        /// The raster fallback run directly on `data`, with a `Tripwire` detector so the page is read as raster.
        private static func fallback(
            _ data: Data, recognizer: (any OMRTextRecognizer)?, log: Fixtures.DiagnosticLog? = nil,
        ) throws -> (content: WalkedContent, pageSizes: [Int: CGSize], rasterPages: Set<Int>) {
            let document = try PDFImporter.openDocument(data)
            let walk = try PDFImporter.walkDocument(document)
            var content = walk.content
            var pageSizes = walk.pageSizes
            var options = PDFImportOptions()
            options.omrDetector = Fixtures.Tripwire()
            options.omrRenderDPI = Fixtures.renderDPI
            options.omrTextRecognizer = recognizer
            if let log {
                options.diagnostics = { log.messages.append($0.message) }
            }
            let rasterPages = PDFImporter.applyRasterFallback(
                to: &content, pageSizes: &pageSizes,
                document: document, detector: Fixtures.Tripwire(), options: options,
            )
            return (content, pageSizes, rasterPages)
        }

        /// One line "text" in strip-image pixels, placed so that only strip 0 keeps it (its centre is in its core).
        private static func line(_ text: String) -> OMRRecognizedLine {
            OMRRecognizedLine(
                text: text, confidence: 0.9, x: 200, y: 20, width: 40, height: 40,
                characters: [OMRRecognizedCharacter(text: text, x: 200, y: 20, width: 40, height: 40)],
            )
        }

        private static func drawStamp(into context: CGContext) {
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let stamp = NSAttributedString(string: "STAMP", attributes: [.font: font])
            context.textPosition = CGPoint(x: 50, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(stamp), context)
        }

        /// An image-only page that also carries one vector text run.
        private static func imageWithVectorTextPDF() throws -> Data {
            try Fixtures.pdf(pages: [{
                try Fixtures.drawBitmap(Fixtures.staffBitmap(), into: $0)
                drawStamp(into: $0)
            }])
        }

        /// Page 0 vector music plus a vector text run, page 1 image-only.
        private static func vectorTextThenImagePDF() throws -> Data {
            try Fixtures.vectorMusic(Fixtures.pdf(pages: [
                {
                    Fixtures.drawVectorStaff(into: $0)
                    drawStamp(into: $0)
                },
                { try Fixtures.drawBitmap(Fixtures.staffBitmap(), into: $0) },
            ]))
        }
    }
#endif
