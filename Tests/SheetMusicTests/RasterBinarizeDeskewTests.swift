#if !os(Android) && !os(WASI)
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

    struct RasterDeskewTests {
        static func skewedStaff(degrees: Double) -> GrayBitmap {
            let bmp = RasterTestBitmaps.staff(
                widthPx: 600, heightPx: 300, dpi: 300, topY: 120, spacingPx: 12,
            )
            return degrees == 0 ? bmp : RasterTestBitmaps.rotated(bmp, degrees: degrees)
        }

        @Test func anUprightPageEstimatesZeroSkew() {
            let mask = RasterPage.binarize(Self.skewedStaff(degrees: 0))
            #expect(abs(RasterPage.estimateSkewDegrees(mask)) <= 0.1)
        }

        @Test(arguments: [-2.0, -1.25, 0.75, 1.5])
        func aSkewedPageRecoversItsAngle(applied: Double) {
            let mask = RasterPage.binarize(Self.skewedStaff(degrees: applied))
            #expect(abs(RasterPage.estimateSkewDegrees(mask) - applied) <= 0.15)
        }

        /// The property the whole stage rests on. At 1.75° across 600px a
        /// staff line's y moves 18px — one and a half staff spaces — so
        /// before deskew the five lines of one staff smear into a single
        /// band and no row-projection detector can separate them.
        @Test func deskewingRestoresFiveDistinctStaffRows() {
            let skewed = Self.skewedStaff(degrees: 1.75)
            let angle = RasterPage.estimateSkewDegrees(RasterPage.binarize(skewed))
            let mask = RasterPage.binarize(RasterPage.rotate(skewed, degrees: -angle))

            var rows: [Int] = []
            for y in 0 ..< mask.height {
                var count = 0
                for x in 0 ..< mask.width where mask[x, y] {
                    count += 1
                }
                rows.append(count)
            }
            let peak = rows.max() ?? 0
            var bands = 0
            var inBand = false
            for count in rows {
                let hot = count >= peak / 2
                if hot, !inBand { bands += 1 }
                inBand = hot
            }
            #expect(bands == 5)
        }

        @Test func rotatingByZeroIsTheIdentity() {
            let bmp = Self.skewedStaff(degrees: 0)
            #expect(RasterPage.rotate(bmp, degrees: 0).pixels == bmp.pixels)
        }
    }
#endif
