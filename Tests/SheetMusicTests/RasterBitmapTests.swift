#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct RasterBitmapTests {
        @Test func aPixelReadsBackTheValueItWasDrawnWith() {
            var bmp = RasterTestBitmaps.blank(widthPx: 10, heightPx: 8, dpi: 300)
            bmp[3, 4] = 0
            #expect(bmp[3, 4] == 0)
            #expect(bmp[4, 4] == 255)
        }

        @Test func pointsPerPixelFollowsDpi() {
            let bmp = RasterTestBitmaps.blank(widthPx: 10, heightPx: 8, dpi: 300)
            #expect(abs(bmp.pointsPerPixel - 72.0 / 300.0) < 1e-12)
        }

        /// Raster space is y-down from the top-left; PDF page space is
        /// y-up from the bottom-left. The top pixel row must map to the
        /// page's TOP, i.e. its LARGEST y. Getting this backwards is
        /// silent — every layout still looks plausible, upside down.
        @Test func theTopPixelRowMapsToTheTopOfThePage() {
            let t = PageTransform(dpi: 300, heightPx: 3300, deskewDegrees: 0)
            #expect(abs(t.point(x: 0, y: 0).y - 792) < 1e-9)
            #expect(abs(t.point(x: 0, y: 3300).y) < 1e-9)
        }

        @Test func pageSizeIsPixelsScaledByDpi() {
            let t = PageTransform(dpi: 300, heightPx: 3300, deskewDegrees: 0)
            let size = t.pageSizePt(widthPx: 2550)
            #expect(abs(size.width - 612) < 1e-9)
            #expect(abs(size.height - 792) < 1e-9)
        }

        @Test func aDrawnHorizontalLineIsInkAcrossItsWholeSpan() {
            var bmp = RasterTestBitmaps.blank(widthPx: 40, heightPx: 20, dpi: 300)
            RasterTestBitmaps.hLine(&bmp, y: 10, x0: 5, x1: 35, thickness: 2)
            #expect(bmp[5, 10] == 0)
            #expect(bmp[34, 10] == 0)
            #expect(bmp[4, 10] == 255)
            #expect(bmp[20, 13] == 255)
        }

        /// A missing page must throw, not yield an empty bitmap that a
        /// sweep would silently score as a page with no content.
        @Test func loadingAMissingPageThrows() {
            let url = URL(fileURLWithPath: "/nonexistent/page_0.png")
            #expect(throws: (any Error).self) {
                try OMRPageBitmapLoader.withPageBitmap(url: url, dpi: 300) { _ in 0 }
            }
        }

        @Test func peakResidentIsReported() {
            #expect(OMRPageBitmapLoader.peakResidentMB() > 0)
        }
    }
#endif
