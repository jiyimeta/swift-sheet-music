#if !os(Android)
    import Foundation
    @testable import SheetMusicPDF

    /// Synthetic bitmaps for the raster unit tests: small enough that a
    /// failure is readable by hand, and drawn with the same conventions
    /// as the real rasters (0 = ink, 255 = paper, y-down).
    enum RasterTestBitmaps {
        static func blank(widthPx: Int, heightPx: Int, dpi: Double) -> GrayBitmap {
            GrayBitmap(
                pixels: [UInt8](repeating: 255, count: widthPx * heightPx),
                width: widthPx, height: heightPx, dpi: dpi,
            )
        }

        static func hLine(
            _ bmp: inout GrayBitmap, y: Int, x0: Int, x1: Int, thickness: Int,
        ) {
            for dy in 0 ..< thickness {
                let row = y + dy
                guard row >= 0, row < bmp.height else { continue }
                for x in max(0, x0) ..< min(bmp.width, x1) {
                    bmp[x, row] = 0
                }
            }
        }

        static func vLine(
            _ bmp: inout GrayBitmap, x: Int, y0: Int, y1: Int, thickness: Int,
        ) {
            for dx in 0 ..< thickness {
                let col = x + dx
                guard col >= 0, col < bmp.width else { continue }
                for y in max(0, y0) ..< min(bmp.height, y1) {
                    bmp[col, y] = 0
                }
            }
        }

        /// A five-line staff spanning most of the page width.
        static func staff(
            widthPx: Int, heightPx: Int, dpi: Double, topY: Int, spacingPx: Int,
        ) -> GrayBitmap {
            var bmp = blank(widthPx: widthPx, heightPx: heightPx, dpi: dpi)
            for i in 0 ..< 5 {
                hLine(
                    &bmp, y: topY + i * spacingPx,
                    x0: widthPx / 20, x1: widthPx - widthPx / 20, thickness: 1,
                )
            }
            return bmp
        }

        /// Nearest-neighbour rotation about the image centre, positive
        /// counter-clockwise, same canvas size, paper outside.
        ///
        /// Nearest-neighbour rather than bilinear on purpose: a fixture
        /// must not soften the ink whose presence the test is checking.
        static func rotated(_ bmp: GrayBitmap, degrees: Double) -> GrayBitmap {
            var out = blank(widthPx: bmp.width, heightPx: bmp.height, dpi: bmp.dpi)
            let cx = Double(bmp.width - 1) / 2
            let cy = Double(bmp.height - 1) / 2
            let t = degrees * .pi / 180
            let c = cos(t)
            let s = sin(t)
            for y in 0 ..< bmp.height {
                let dy = Double(y) - cy
                for x in 0 ..< bmp.width {
                    let dx = Double(x) - cx
                    let sx = Int((c * dx + s * dy + cx).rounded())
                    let sy = Int((-s * dx + c * dy + cy).rounded())
                    guard sx >= 0, sx < bmp.width, sy >= 0, sy < bmp.height else { continue }
                    out[x, y] = bmp[sx, sy]
                }
            }
            return out
        }
    }
#endif
