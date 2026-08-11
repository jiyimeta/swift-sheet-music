#if !os(Android)
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct RasterBinarizeTests {
        @Test func otsuSplitsAClearlyBimodalPage() {
            var bmp = RasterTestBitmaps.blank(widthPx: 40, heightPx: 40, dpi: 300)
            RasterTestBitmaps.hLine(&bmp, y: 20, x0: 0, x1: 40, thickness: 4)
            let t = RasterPage.otsuThreshold(bmp)
            #expect(t > 0)
            #expect(t < 255)
        }

        @Test func binarizeMarksInkTrueAndPaperFalse() {
            var bmp = RasterTestBitmaps.blank(widthPx: 40, heightPx: 40, dpi: 300)
            RasterTestBitmaps.hLine(&bmp, y: 20, x0: 5, x1: 35, thickness: 2)
            let mask = RasterPage.binarize(bmp)
            #expect(mask[10, 20])
            #expect(!mask[10, 5])
        }

        /// The degradation profile has an illumination-gradient stage, so
        /// one edge of a page can be far darker than the other. A single
        /// global threshold on the RAW image then either loses the ink in
        /// the bright corner or floods the dark one; flattening first is
        /// what keeps one threshold usable across the page.
        @Test func flatteningRecoversInkUnderAStrongIlluminationGradient() {
            var bmp = RasterTestBitmaps.blank(widthPx: 200, heightPx: 60, dpi: 300)
            RasterTestBitmaps.hLine(&bmp, y: 30, x0: 0, x1: 200, thickness: 2)
            for y in 0 ..< bmp.height {
                for x in 0 ..< bmp.width {
                    let drop = 120.0 * Double(x) / Double(bmp.width)
                    bmp[x, y] = UInt8(max(0, Double(bmp[x, y]) - drop))
                }
            }
            let mask = RasterPage.binarize(bmp)
            let inked = (0 ..< bmp.width).filter { mask[$0, 30] || mask[$0, 31] }
            #expect(inked.count > 190)
        }

        /// A page with no ink at all must binarize to no ink, rather than
        /// to a threshold that turns half the paper black.
        @Test func aBlankPageHasNoInk() {
            let bmp = RasterTestBitmaps.blank(widthPx: 40, heightPx: 40, dpi: 300)
            let mask = RasterPage.binarize(bmp)
            #expect(!mask.bits.contains(true))
        }
    }
#endif
