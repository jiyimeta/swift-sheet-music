#if !os(Android)
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct OMRRasterFrontEndTests {
        struct StubDetector: OMRGlyphDetecting {
            var glyphs: [ClassifiedGlyph]
            func glyphs(
                pageIndex _: Int, analysis _: RasterPageAnalysis,
                diagnostics _: (@Sendable (PDFImportDiagnostic) -> Void)?,
            ) throws -> [ClassifiedGlyph] {
                glyphs
            }
        }

        /// `RasterTestBitmaps` has no `fiveLineStaff` constructor; `staff`
        /// is the fixture it actually provides, with the same shape used
        /// throughout the raster tests.
        static func fiveLineStaff(width: Int, height: Int, dpi: Double) -> GrayBitmap {
            RasterTestBitmaps.staff(
                widthPx: width, heightPx: height, dpi: dpi, topY: 150, spacingPx: 14,
            )
        }

        /// The page size must come from the ANALYSIS's own frame. A degraded page
        /// has been resampled, so its pixel size is not the clean page size times
        /// dpi/72; taking it from anywhere else shifts every path relative to every
        /// glyph, invisibly, because on a clean raster the frames coincide.
        @Test func pageSizeComesFromTheAnalysisTransform() throws {
            let bitmap = Self.fiveLineStaff(width: 600, height: 400, dpi: 300)
            let result = try RasterFrontEnd.page(
                bitmap: bitmap, pageIndex: 0, detector: StubDetector(glyphs: []), diagnostics: nil,
            )
            let analysis = RasterPage.analyze(bitmap, pageIndex: 0)
            #expect(result.pageSize == analysis.pageSizePt)
        }

        /// Raster pages carry no text and no curves — there is no OCR and no curve
        /// detector. Stated as a test so it is a decision, not an oversight.
        @Test func textsAndCurvesAreEmpty() throws {
            let bitmap = Self.fiveLineStaff(width: 600, height: 400, dpi: 300)
            let result = try RasterFrontEnd.page(
                bitmap: bitmap, pageIndex: 0, detector: StubDetector(glyphs: []), diagnostics: nil,
            )
            #expect(result.walked.texts.isEmpty)
            #expect(result.walked.curves.isEmpty)
        }

        /// The paths are the raster analysis's, unedited: this is what makes the
        /// harness's `.full` mode and the product path the same computation.
        @Test func pathsAreTheAnalysisPathsUnchanged() throws {
            let bitmap = Self.fiveLineStaff(width: 600, height: 400, dpi: 300)
            let result = try RasterFrontEnd.page(
                bitmap: bitmap, pageIndex: 0, detector: StubDetector(glyphs: []), diagnostics: nil,
            )
            #expect(result.walked.paths == RasterPage.analyze(bitmap, pageIndex: 0).paths)
            #expect(!result.walked.paths.isEmpty, "the stub staff must yield staff-line paths")
        }
    }
#endif
