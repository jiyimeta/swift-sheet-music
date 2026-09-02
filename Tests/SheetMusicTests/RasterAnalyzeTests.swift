#if !os(Android) && !os(WASI)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct RasterPageAnalyzeTests {
        static func staffPage() -> GrayBitmap {
            RasterTestBitmaps.staff(
                widthPx: 1200, heightPx: 400, dpi: 300, topY: 150, spacingPx: 14,
            )
        }

        /// The whole point of the stage: raster output must reach
        /// `detectStaves` — the existing, corpus-hardened five-line
        /// grouper — and be read by it. A second grouper is deliberately
        /// not written; reusing this one is what the seam buys.
        @Test func aSyntheticPageReachesTheExistingStaffDetector() {
            var bmp = Self.staffPage()
            RasterTestBitmaps.vLine(&bmp, x: 1130, y0: 150, y1: 207, thickness: 3)
            let analysis = RasterPage.analyze(bmp, pageIndex: 0)
            #expect(analysis.staffSpacingPt > 0)

            let staves = PDFImporter.detectStaves(
                paths: analysis.paths, classified: [], pageIndex: 0,
            )
            #expect(staves.count == 1)
            #expect(staves.first?.yLines.count == 5)
        }

        @Test func aSkewedPageReportsTheAngleItRemoved() {
            let skewed = RasterTestBitmaps.rotated(Self.staffPage(), degrees: 1.5)
            let analysis = RasterPage.analyze(skewed, pageIndex: 0)
            #expect(abs(analysis.deskewDegrees - 1.5) <= 0.2)
            #expect(analysis.transform.deskewDegrees == analysis.deskewDegrees)
        }

        /// A skewed page must still reach `detectStaves` with five lines.
        /// Before deskew its five lines smear across nearly two staff
        /// spaces and the detector sees one thick band, not a staff.
        @Test func aSkewedPageStillYieldsOneFiveLineStaff() {
            let skewed = RasterTestBitmaps.rotated(Self.staffPage(), degrees: 1.5)
            let analysis = RasterPage.analyze(skewed, pageIndex: 0)
            let staves = PDFImporter.detectStaves(
                paths: analysis.paths, classified: [], pageIndex: 0,
            )
            #expect(staves.count == 1)
            #expect(staves.first?.yLines.count == 5)
        }

        @Test func aBlankPageYieldsNoPathsAndDoesNotCrash() {
            let blank = RasterTestBitmaps.blank(widthPx: 400, heightPx: 400, dpi: 300)
            let analysis = RasterPage.analyze(blank, pageIndex: 0)
            #expect(analysis.paths.isEmpty)
            #expect(analysis.staffSpacingPt == 0)
        }

        /// Analysis must be a pure function of the bitmap — the run-twice
        /// gate depends on it, and every component labeler in this stage
        /// walks in raster-scan order for exactly this reason.
        @Test func analysisIsDeterministic() {
            let bmp = Self.staffPage()
            let first = RasterPage.analyze(bmp, pageIndex: 0)
            let second = RasterPage.analyze(bmp, pageIndex: 0)
            #expect(first.paths == second.paths)
            #expect(first.staffSpacingPt == second.staffSpacingPt)
        }

        @Test func analyzeDropsTheDeskewedPageUnlessAsked() {
            let bitmap = RasterTestBitmaps.staff(
                widthPx: 400, heightPx: 300, dpi: 300, topY: 100, spacingPx: 8,
            )
            #expect(RasterPage.analyze(bitmap, pageIndex: 0).deskewed == nil)
        }

        @Test func analyzeKeepsTheDeskewedPageWhenAsked() {
            let bitmap = RasterTestBitmaps.staff(
                widthPx: 400, heightPx: 300, dpi: 300, topY: 100, spacingPx: 8,
            )
            let analysis = RasterPage.analyze(bitmap, pageIndex: 0, keepDeskewed: true)
            // Deskew preserves the canvas, so the kept page is the transform's
            // own size — that is what makes it safe to index with the transform.
            #expect(analysis.deskewed?.width == analysis.transform.widthPx)
            #expect(analysis.deskewed?.height == analysis.transform.heightPx)
            #expect(analysis.deskewed?.dpi == bitmap.dpi)
        }

        @Test func aStafflessPageStillCarriesTheDeskewedPage() {
            // The early return (no staff spacing) is a separate exit and had to
            // be wired too; a blank page takes it.
            let blank = RasterTestBitmaps.blank(widthPx: 200, heightPx: 200, dpi: 300)
            let analysis = RasterPage.analyze(blank, pageIndex: 0, keepDeskewed: true)
            #expect(analysis.staffSpacingPt == 0)
            #expect(analysis.deskewed != nil)
        }

        @Test func staffSpacingInPixelsInvertsThePointConversion() {
            let bitmap = RasterTestBitmaps.staff(
                widthPx: 400, heightPx: 300, dpi: 300, topY: 100, spacingPx: 8,
            )
            let analysis = RasterPage.analyze(bitmap, pageIndex: 0)
            #expect(abs(analysis.staffSpacingPx - 8.0) < 0.5)
        }
    }
#endif
