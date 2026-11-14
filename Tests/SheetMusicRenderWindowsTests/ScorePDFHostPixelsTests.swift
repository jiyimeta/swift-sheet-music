import Foundation
import SheetMusicRenderWindows
import Testing

/// `ScorePDF.pixels(page:pxPerMM:)` as a host reaches it — imported without `@testable` — and handed to a frame
/// canvas, as folino's score video composites its wordmark; and the bundled metrics table a host measures a video in.
struct ScorePDFHostPixelsTests {
    @Test func `a host reads the bundled metrics table`() throws {
        let path = ScoreSurface.bundledMetricsTableFile
        #expect(path.hasSuffix("sheet-music.smft"))
        let bytes = try #require(FileManager.default.contents(atPath: path))
        #expect(bytes.count > 1000)
    }

    @Test func `a host draws a PDF page's pixels on a frame canvas`() throws {
        let pdf = try ScorePDF(path: ScorePDFTests.squarePDF())
        let drawn = try pdf.pixels(page: 0, pxPerMM: 1) // 210 × 297 px
        #expect(drawn.width == 210)
        #expect(drawn.height == 297)

        let canvas = try Direct2DFrameCanvas(widthPx: 210, heightPx: 297, fontFiles: [])
        try canvas.clear(argb: 0xFFFF_FFFF)
        try drawn.bgra.withUnsafeBytes {
            try canvas.draw(
                pixels: $0, widthPx: drawn.width, heightPx: drawn.height, in: (x: 0, y: 0, width: 210, height: 297),
                opacity: 1,
            )
        }
        let pixels = try canvas.pixels()
        // The square's centre (144 pt, 99.89 pt from the top-left, at 1 px per mm) is black, a corner white.
        let millimetresPerPoint = 25.4 / 72
        let centre = (Int(99.89 * millimetresPerPoint) * 210 + Int(144 * millimetresPerPoint)) * 4
        #expect(Array(pixels[centre ..< centre + 3]) == [0, 0, 0])
        #expect(Array(pixels[0 ..< 3]) == [255, 255, 255])
    }
}
