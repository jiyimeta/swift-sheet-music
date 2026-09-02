#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// The fixtures `PDFImporterRasterFallbackTests` reads: the vector,
    /// image-only and mixed two-staff documents, and the detector stand-ins.
    /// Split from the tests so each file stays under the length lint.
    extension PDFImporterRasterFallbackTests {
        // MARK: - Fixtures

        /// Every fixture page in this file is this size, so one `CGContext`
        /// can emit a mixed document without per-page media boxes.
        static let pageSize = CGSize(width: 300, height: 200)
        static let renderDPI: Double = 300

        /// TWO five-line staves per fixture page, not one, and that is
        /// load-bearing: `ensembleStaffCount` discards any page whose staff
        /// count is below 2 and reports `nil` for a GCD below 2, so a
        /// one-staff-per-page fixture would leave `ensembleSize` at `nil` in
        /// BOTH arms of the mixed-document test — there would be no ensemble
        /// for a miscounting raster page to collapse, and the test would
        /// exercise none of the coupling it exists for.
        /// `bothFixturePagesCarryATwoStaffEnsemble` checks the fixture still
        /// clears that gate rather than trusting these constants.
        static let staffBandCount = 2

        /// The image page's bitmap, sized so that rasterizing the PDF page it
        /// is drawn into at `renderDPI` reproduces it 1:1.
        ///
        /// Line shape and thickness match the fixture `OMRRasterFrontEndTests`
        /// already proves yields staff-line paths; only the scale and the band
        /// count differ, so the staff spacing (29px ≈ 7pt) clears
        /// `detectStaves`' `lineMergeTolerance` of 2pt and the lines clear its
        /// 50pt width gate. The 350px gap between bands is far outside the
        /// 29px line spacing, so the CV window cannot read the two bands as
        /// one ten-line staff.
        static func staffBitmap() -> GrayBitmap {
            let widthPx = Int((pageSize.width * renderDPI / 72).rounded())
            let heightPx = Int((pageSize.height * renderDPI / 72).rounded())
            var bitmap = RasterTestBitmaps.blank(
                widthPx: widthPx, heightPx: heightPx, dpi: renderDPI,
            )
            for band in 0 ..< staffBandCount {
                for line in 0 ..< 5 {
                    RasterTestBitmaps.hLine(
                        &bitmap, y: 150 + band * 350 + line * 29,
                        x0: widthPx / 20, x1: widthPx - widthPx / 20, thickness: 1,
                    )
                }
            }
            return bitmap
        }

        /// The five-line staves the vector walker reads, as stroked paths —
        /// the shape `PDFImporterFaçadeTests` proves `buildScore` accepts,
        /// twice, for the reason on `staffBandCount`.
        static func drawVectorStaff(into context: CGContext) {
            context.setLineWidth(0.5)
            context.setStrokeColor(gray: 0, alpha: 1)
            for band in 0 ..< staffBandCount {
                for line in 0 ..< 5 {
                    let y = CGFloat(30 + band * 100 + line * 10)
                    context.beginPath()
                    context.move(to: CGPoint(x: 25, y: y))
                    context.addLine(to: CGPoint(x: 275, y: y))
                    context.strokePath()
                }
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
            case detectorFailed(Int)
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

        /// Stands in for every way one page's read can fail — a `CGContext`
        /// the rasterizer cannot create, a model that throws mid-document.
        struct FailingDetector: OMRGlyphDetecting {
            func glyphs(
                pageIndex: Int, analysis _: RasterPageAnalysis,
                diagnostics _: (@Sendable (PDFImportDiagnostic) -> Void)?,
            ) throws -> [ClassifiedGlyph] {
                throw FixtureError.detectorFailed(pageIndex)
            }
        }
    }
#endif
