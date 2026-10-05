@testable import SheetMusicRenderWindows
import Testing

/// Which part of a PDF page the surface draws into one band (`PDFPageRaster`). The large page is A4 at 8× zoom on a
/// 200 % screen, 12,700 × 17,960 px — past the 4096 px cap — seen through a 1600 × 1000 px view.
struct PDFPageRasterTests {
    private static let width = 12700
    private static let height = 17960

    @Test func `a page that fits the cap is drawn whole whatever part of it shows`() throws {
        let view = PixelRect(x: 300, y: -200, width: 1600, height: 1000)

        let needed = try #require(PDFPageRaster.needed(view: view, pageWidthPx: 1588, pageHeightPx: 2246))

        #expect(needed == PixelRect(x: 0, y: 0, width: 1588, height: 2246))
        #expect(PDFPageRaster.drawn(needed: needed, pageWidthPx: 1588, pageHeightPx: 2246) == needed)
    }

    @Test func `a view that misses the page needs nothing of it`() {
        let view = PixelRect(x: 0, y: 2300, width: 1600, height: 1000)

        #expect(PDFPageRaster.needed(view: view, pageWidthPx: 1588, pageHeightPx: 2246) == nil)
    }

    @Test func `past the cap the band holds the view grown by half of it on each side`() throws {
        let view = PixelRect(x: 5000, y: 8000, width: 1600, height: 1000)

        let needed = try #require(PDFPageRaster.needed(view: view, pageWidthPx: Self.width, pageHeightPx: Self.height))
        let drawn = PDFPageRaster.drawn(needed: needed, pageWidthPx: Self.width, pageHeightPx: Self.height)

        #expect(needed == view)
        #expect(drawn == PixelRect(x: 4200, y: 7500, width: 3200, height: 2000))
        #expect(PDFPageRaster.covers(drawn, needed))
    }

    @Test func `at the page's corners the band stays on the page and still holds the view`() throws {
        let topLeft = try #require(PDFPageRaster.needed(
            view: PixelRect(x: -100, y: -50, width: 1600, height: 1000), pageWidthPx: Self.width,
            pageHeightPx: Self.height,
        ))
        let bottomRight = try #require(PDFPageRaster.needed(
            view: PixelRect(x: 12000, y: 17500, width: 1600, height: 1000), pageWidthPx: Self.width,
            pageHeightPx: Self.height,
        ))

        let first = PDFPageRaster.drawn(needed: topLeft, pageWidthPx: Self.width, pageHeightPx: Self.height)
        let last = PDFPageRaster.drawn(needed: bottomRight, pageWidthPx: Self.width, pageHeightPx: Self.height)

        #expect(topLeft == PixelRect(x: 0, y: 0, width: 1500, height: 950))
        #expect(first == PixelRect(x: 0, y: 0, width: 3000, height: 1900))
        #expect(bottomRight == PixelRect(x: 12000, y: 17500, width: 700, height: 460))
        #expect(last == PixelRect(x: 11300, y: 17040, width: 1400, height: 920))
        #expect(PDFPageRaster.covers(first, topLeft))
        #expect(PDFPageRaster.covers(last, bottomRight))
    }

    @Test func `a view longer than the cap needs its middle, and the band is that middle`() throws {
        let view = PixelRect(x: 0, y: 0, width: 5000, height: 5000)

        let needed = try #require(PDFPageRaster.needed(view: view, pageWidthPx: 5000, pageHeightPx: 20000))
        let drawn = PDFPageRaster.drawn(needed: needed, pageWidthPx: 5000, pageHeightPx: 20000)

        #expect(needed == PixelRect(x: 452, y: 452, width: 4096, height: 4096))
        #expect(drawn == needed)
    }

    @Test func `a view that leaves the band is not covered by it`() throws {
        let first = try #require(PDFPageRaster.needed(
            view: PixelRect(x: 5000, y: 8000, width: 1600, height: 1000), pageWidthPx: Self.width,
            pageHeightPx: Self.height,
        ))
        let drawn = PDFPageRaster.drawn(needed: first, pageWidthPx: Self.width, pageHeightPx: Self.height)
        // Half a view down still fits inside the band; a whole view down does not.
        let halfDown = PixelRect(x: 5000, y: 8500, width: 1600, height: 1000)
        let wholeDown = PixelRect(x: 5000, y: 9000, width: 1600, height: 1000)

        #expect(PDFPageRaster.covers(drawn, halfDown))
        #expect(!PDFPageRaster.covers(drawn, wholeDown))
    }
}
