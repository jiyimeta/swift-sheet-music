#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    import SheetMusicOMRModel
    @testable import SheetMusicPDF
    import Testing

    /// The public tap: `PDFImportOptions.omrTileClassifier` turning
    /// `PDFImporter.parse` into something that can read a scanned page, and
    /// the per-page gate that decides which pages it reads.
    struct PDFImporterRasterFallbackTests {
        // MARK: - Fixtures

        /// Every fixture page in this file is this size, so one `CGContext`
        /// can emit a mixed document without per-page media boxes.
        static let pageSize = CGSize(width: 300, height: 200)
        static let renderDPI: Double = 300

        /// The image page's bitmap, sized so that rasterizing the PDF page it
        /// is drawn into at `renderDPI` reproduces it 1:1.
        ///
        /// Shape and thickness match the fixture `OMRRasterFrontEndTests`
        /// already proves yields staff-line paths; only the scale differs, so
        /// the staff spacing (29px ≈ 7pt) clears `detectStaves`'
        /// `lineMergeTolerance` of 2pt and the lines clear its 50pt width gate.
        static func staffBitmap() -> GrayBitmap {
            RasterTestBitmaps.staff(
                widthPx: Int((pageSize.width * renderDPI / 72).rounded()),
                heightPx: Int((pageSize.height * renderDPI / 72).rounded()),
                dpi: renderDPI, topY: 300, spacingPx: 29,
            )
        }

        /// The five-line staff the vector walker reads, as stroked paths —
        /// the minimum `PDFImporterFaçadeTests` proves `buildScore` accepts.
        static func drawVectorStaff(into context: CGContext) {
            context.setLineWidth(0.5)
            context.setStrokeColor(gray: 0, alpha: 1)
            for i in 0 ..< 5 {
                let y = CGFloat(80 + i * 10)
                context.beginPath()
                context.move(to: CGPoint(x: 25, y: y))
                context.addLine(to: CGPoint(x: 275, y: y))
                context.strokePath()
            }
        }

        static func drawBitmap(_ bitmap: GrayBitmap, into context: CGContext) throws {
            let bytes = Data(bitmap.pixels)
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let image = CGImage(
                      width: bitmap.width, height: bitmap.height,
                      bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bitmap.width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false,
                      intent: .defaultIntent,
                  )
            else {
                throw FixtureError.cannotBuildImage
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(origin: .zero, size: pageSize))
        }

        enum FixtureError: Error {
            case cannotBuildImage
            case cannotBuildPDF
        }

        /// One in-memory PDF, one closure per page.
        static func pdf(pages: [(CGContext) throws -> Void]) throws -> Data {
            let data = NSMutableData()
            var box = CGRect(origin: .zero, size: pageSize)
            guard let consumer = CGDataConsumer(data: data),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil)
            else {
                throw FixtureError.cannotBuildPDF
            }
            for page in pages {
                context.beginPDFPage(nil)
                try page(context)
                context.endPDFPage()
            }
            context.closePDF()
            return data as Data
        }

        /// Wraps a `GrayBitmap` as a one-page, image-only PDF — zero vector
        /// content, which is what a scan looks like to the importer.
        static func imageOnlyPDF(_ bitmap: GrayBitmap) throws -> Data {
            try pdf(pages: [{ try drawBitmap(bitmap, into: $0) }])
        }

        static func vectorPDF() throws -> Data {
            try pdf(pages: [{ drawVectorStaff(into: $0) }])
        }

        /// Page 0 vector, page 1 image-only.
        static func mixedPDF() throws -> Data {
            try pdf(pages: [
                { drawVectorStaff(into: $0) },
                { try drawBitmap(staffBitmap(), into: $0) },
            ])
        }

        /// `PDFImporter`'s own internal `Staff`, not `SheetMusicCore.Staff`:
        /// `ensembleStaffCount` only reads `count`, so the field values are
        /// irrelevant and are left empty on purpose.
        static func detectedStaves(_ count: Int) -> [SheetMusicPDF.Staff] {
            (0 ..< count).map { _ in
                SheetMusicPDF.Staff(
                    pageIndex: 0, yLines: [], xRange: 0 ... 0, barlineCandidates: [],
                )
            }
        }

        /// Break flags are a property of what FOLLOWS a measure, not of how it
        /// was read: the vector page's last measure necessarily gains a
        /// line/page break once a second page exists behind it. Everything
        /// else about the measure — its voices, repeats, markers, length — is
        /// the reading, and that is what must not move.
        static func ignoringBreaks(_ measures: [Measure]) -> [Measure] {
            measures.map {
                var m = $0
                m.lineBreak = false
                m.pageBreak = false
                m.sectionBreak = false
                return m
            }
        }

        /// Records which pages the importer handed to a glyph detector.
        final class Tripwire: OMRGlyphDetecting, @unchecked Sendable {
            var pagesAsked: [Int] = []
            func glyphs(
                pageIndex: Int, analysis _: RasterPageAnalysis,
                diagnostics _: (@Sendable (PDFImportDiagnostic) -> Void)?,
            ) throws -> [ClassifiedGlyph] {
                pagesAsked.append(pageIndex)
                return []
            }
        }

        /// Collects diagnostics from the `@Sendable` callback.
        final class DiagnosticLog: @unchecked Sendable {
            var messages: [String] = []
        }

        // MARK: - Tests

        /// G3a: with a classifier set, an image-only PDF reaches `buildScore`.
        /// Without one, it does not — which is what makes the knob meaningful.
        @Test func anImageOnlyPageIsReadOnlyWhenAClassifierIsSet() async throws {
            let data = try Self.imageOnlyPDF(Self.staffBitmap())
            #expect(throws: (any Error).self) {
                try PDFImporter.parse(pdfData: data, options: PDFImportOptions())
            }

            var options = PDFImportOptions()
            options.omrTileClassifier = try await CoreMLTileClassifier()
            options.omrRenderDPI = Self.renderDPI
            let score = try PDFImporter.parse(pdfData: data, options: options)
            #expect(!score.parts.isEmpty)
        }

        /// The per-page gate, in both directions. A page the vector walker
        /// filled must NOT reach the detector; a page it left empty MUST.
        ///
        /// Both directions matter: asserting only "not asked" would pass even
        /// if the fallback were deleted outright, and a test that cannot fail
        /// is this repository's most-recorded defect class.
        @Test func theDetectorIsAskedOnlyForPagesWithNoVectorContent() {
            let onVector = Tripwire()
            var vectorOptions = PDFImportOptions()
            vectorOptions.omrDetector = onVector
            vectorOptions.omrRenderDPI = Self.renderDPI
            _ = try? PDFImporter.parse(pdfData: Self.vectorPDF(), options: vectorOptions)
            #expect(onVector.pagesAsked.isEmpty, "a page with vector content must not be rasterized")

            let onImage = Tripwire()
            var imageOptions = PDFImportOptions()
            imageOptions.omrDetector = onImage
            imageOptions.omrRenderDPI = Self.renderDPI
            _ = try? PDFImporter.parse(
                pdfData: Self.imageOnlyPDF(Self.staffBitmap()), options: imageOptions,
            )
            #expect(onImage.pagesAsked == [0], "an image-only page must reach the detector exactly once")
        }

        /// `nil` means today's behavior LITERALLY: no rasterization, no
        /// detection, no new pass over the pages. The corpus gate is only
        /// meaningful because of this, so it is asserted directly rather than
        /// inferred from the corpus staying byte-identical.
        @Test func noClassifierAndNoDetectorEntersNoNewCodePath() throws {
            let tripwire = Tripwire()
            var options = PDFImportOptions()
            options.omrDetector = tripwire
            // The same document, once with the detector and once without.
            let data = try Self.imageOnlyPDF(Self.staffBitmap())
            _ = try? PDFImporter.parse(pdfData: data, options: options)
            #expect(tripwire.pagesAsked == [0], "the injected detector is what makes the page readable")

            let untouched = Tripwire()
            #expect(throws: (any Error).self) {
                try PDFImporter.parse(pdfData: data, options: PDFImportOptions())
            }
            #expect(untouched.pagesAsked.isEmpty)
        }

        /// G3c: one vector page and one image-only page in the same document.
        /// The vector page's own reading must be unchanged from parsing it
        /// alone — `buildScore` derives ONE document-wide ensemble staff count
        /// as a GCD over every page, so a raster page that miscounts can drop
        /// every page, vector ones included, onto the per-page heuristic.
        @Test func aMixedDocumentLeavesTheVectorPageUnchanged() async throws {
            var options = PDFImportOptions()
            options.omrTileClassifier = try await CoreMLTileClassifier()
            options.omrRenderDPI = Self.renderDPI
            let mixed = try PDFImporter.parse(pdfData: Self.mixedPDF(), options: options)
            let vectorAlone = try PDFImporter.parse(
                pdfData: Self.vectorPDF(), options: PDFImportOptions(),
            )
            #expect(mixed.parts.count == vectorAlone.parts.count)
            // The vector page is page 0 of both documents, so its measures are
            // the PREFIX of the mixed document's. Comparing totals instead
            // would only pass while the raster page contributes nothing —
            // i.e. it would pass for the wrong reason.
            let mixedMeasures = try #require(mixed.parts.first?.staves.first?.measures)
            let aloneMeasures = try #require(vectorAlone.parts.first?.staves.first?.measures)
            #expect(!aloneMeasures.isEmpty, "the vector page must read as at least one measure")
            #expect(
                mixedMeasures.count > aloneMeasures.count,
                "the raster page must contribute measures of its own, or this test passes blind",
            )
            #expect(
                Self.ignoringBreaks(Array(mixedMeasures.prefix(aloneMeasures.count)))
                    == Self.ignoringBreaks(aloneMeasures),
            )
        }

        /// The coupling mechanism itself, directly — so a failure names the
        /// cause instead of pointing at a document-level symptom.
        @Test func oneMiscountingPageCollapsesTheEnsembleGCD() {
            let eight = Self.detectedStaves(8)
            let seven = Self.detectedStaves(7)
            #expect(PDFImporter.ensembleStaffCount([eight, eight]) == 8)
            #expect(
                PDFImporter.ensembleStaffCount([eight, seven]) == nil,
                "GCD(8,7)=1, which the importer reports as no usable ensemble",
            )
        }

        /// §9: a page the importer cannot read must say why, and name the knob.
        @Test func anUnreadableImagePageNamesTheKnob() throws {
            let log = DiagnosticLog()
            var options = PDFImportOptions()
            options.diagnostics = { log.messages.append($0.message) }
            var thrown: String?
            do {
                _ = try PDFImporter.parse(
                    pdfData: Self.imageOnlyPDF(Self.staffBitmap()), options: options,
                )
            } catch let SheetMusicError.malformedScore(fault) {
                thrown = fault.message
            }
            #expect(log.messages.contains { $0.contains("omrTileClassifier") })
            #expect(thrown?.contains("omrTileClassifier") == true)
        }

        /// §7: `parseWithGeometry` and the pure-Swift reader take the same
        /// options and do nothing with this one. A knob that silently does
        /// nothing is this repository's own silent-drop smell, so those entry
        /// points say so.
        @Test func theGeometryEntryPointSaysItDoesNotRasterize() async throws {
            let log = DiagnosticLog()
            var options = PDFImportOptions()
            options.omrTileClassifier = try await CoreMLTileClassifier()
            options.diagnostics = { log.messages.append($0.message) }
            _ = try? PDFImporter.parseWithGeometry(
                pdfData: Self.imageOnlyPDF(Self.staffBitmap()), options: options,
            )
            #expect(log.messages.contains { $0.contains("does not rasterize") })
        }

        @Test func theSwiftReaderEntryPointSaysItDoesNotRasterize() async throws {
            let log = DiagnosticLog()
            var options = PDFImportOptions()
            options.omrTileClassifier = try await CoreMLTileClassifier()
            options.diagnostics = { log.messages.append($0.message) }
            _ = try? PDFImporter.parseUsingSwiftReader(
                pdfData: Self.imageOnlyPDF(Self.staffBitmap()), options: options,
            )
            #expect(log.messages.contains { $0.contains("does not rasterize") })
        }
    }
#endif
