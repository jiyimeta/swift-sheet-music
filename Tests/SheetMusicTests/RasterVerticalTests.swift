#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct RasterVerticalTests {
        static func transform(_ bmp: GrayBitmap) -> PageTransform {
            PageTransform(dpi: bmp.dpi, heightPx: bmp.height, deskewDegrees: 0)
        }

        static func verticals(_ bmp: GrayBitmap) -> [PathSegment] {
            RasterPage.verticalSegments(
                RasterPage.binarize(bmp), spacingPx: 12,
                transform: transform(bmp), pageIndex: 0,
            )
        }

        @Test func aStemBecomesOneVerticalSegment() {
            var bmp = RasterTestBitmaps.blank(widthPx: 300, heightPx: 200, dpi: 300)
            RasterTestBitmaps.vLine(&bmp, x: 100, y0: 40, y1: 82, thickness: 2)
            let segs = Self.verticals(bmp)
            #expect(segs.count == 1)
            #expect(segs[0].kind == .vertical)
        }

        /// Notehead interiors and staff-line crossings produce short
        /// column runs in the thousands. Filtering them is noise removal,
        /// not classification.
        @Test func inkShorterThanTheMinimumIsNotEmitted() {
            var bmp = RasterTestBitmaps.blank(widthPx: 300, heightPx: 200, dpi: 300)
            RasterTestBitmaps.vLine(&bmp, x: 100, y0: 40, y1: 48, thickness: 2)
            #expect(Self.verticals(bmp).isEmpty)
        }

        /// Stems (~3.5 staff spaces) and barlines (exactly the 4.0-space
        /// staff height) overlap in length — measured on this dataset the
        /// distribution peaks at 3.0sp with 8,036 samples and at 4.0sp
        /// with 7,848. Separating them here is impossible, and
        /// unnecessary: `barlineCandidates` already does it downstream
        /// using notehead abutment, which this stage has no access to.
        @Test func aStemAndABarlineBothArriveAsPlainVerticals() {
            var bmp = RasterTestBitmaps.blank(widthPx: 300, heightPx: 200, dpi: 300)
            RasterTestBitmaps.vLine(&bmp, x: 60, y0: 40, y1: 82, thickness: 2)
            RasterTestBitmaps.vLine(&bmp, x: 220, y0: 40, y1: 88, thickness: 3)
            let segs = Self.verticals(bmp)
            #expect(segs.count == 2)
            #expect(Set(segs.map(\.kind)) == [.vertical])
        }

        @Test func segmentWidthBecomesTheMeasuredLineWidth() {
            var bmp = RasterTestBitmaps.blank(widthPx: 300, heightPx: 200, dpi: 300)
            RasterTestBitmaps.vLine(&bmp, x: 100, y0: 40, y1: 88, thickness: 5)
            let segs = Self.verticals(bmp)
            #expect(segs.count == 1)
            #expect(abs(Double(segs[0].lineWidth) - 5 * 72.0 / 300.0) < 0.05)
        }

        @Test func verticalsAreEmittedLeftToRight() {
            var bmp = RasterTestBitmaps.blank(widthPx: 400, heightPx: 200, dpi: 300)
            for x in [300, 100, 200] {
                RasterTestBitmaps.vLine(&bmp, x: x, y0: 40, y1: 88, thickness: 2)
            }
            let xs = Self.verticals(bmp).map(\.rect.midX)
            #expect(xs == xs.sorted())
        }

        /// A vertical's rect must span its ink in PAGE space, y-up. A
        /// stem drawn over raster rows 40..87 of a 200px page at 300dpi
        /// runs from (200−88)×0.24 = 26.88pt up to (200−40)×0.24 =
        /// 38.4pt, i.e. 11.52pt tall.
        @Test func verticalsSpanTheirInkInPageSpace() {
            var bmp = RasterTestBitmaps.blank(widthPx: 300, heightPx: 200, dpi: 300)
            RasterTestBitmaps.vLine(&bmp, x: 100, y0: 40, y1: 88, thickness: 2)
            let seg = try? #require(Self.verticals(bmp).first)
            #expect(abs(Double(seg?.rect.minY ?? 0) - 26.88) < 0.3)
            #expect(abs(Double(seg?.rect.maxY ?? 0) - 38.4) < 0.3)
        }
    }
#endif
