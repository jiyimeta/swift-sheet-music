#if !os(Android)
    import Foundation
    @testable import SheetMusicPDF

    /// Deskewed page → the detector's canonical scale: one staff space is
    /// exactly `targetStaffSpacePx` pixels.
    ///
    /// **This is the only implementation of the detector's preprocessing**
    /// (design §3.1). The training data is produced by calling it, and
    /// inference produces its input by calling it — Python never
    /// reimplements deskew or scale, because a drift between two
    /// implementations does not crash, it presents as "the detector is
    /// bad". That exact failure already cost this program a round: the
    /// first degraded seam sweep read 0.20 staff-line recall against a
    /// Python probe's 0.91, and the whole gap was an unmapped frame.
    ///
    /// Bilinear rather than nearest: at the canonical scale a staff line
    /// is around one pixel thick, and nearest-neighbour resampling drops
    /// or doubles such a line depending on sub-pixel phase.
    enum OMRPrepNormalize {
        struct Result {
            var bitmap: GrayBitmap
            /// Normalized pixels per deskewed pixel.
            var scale: Double
        }

        static func normalize(
            _ bitmap: GrayBitmap, staffSpacingPx: Double, targetStaffSpacePx: Double,
        ) -> Result? {
            guard staffSpacingPx > 0, targetStaffSpacePx > 0 else { return nil }
            let scale = targetStaffSpacePx / staffSpacingPx
            guard scale != 1.0 else { return Result(bitmap: bitmap, scale: 1.0) }
            let width = max(1, Int((Double(bitmap.width) * scale).rounded()))
            let height = max(1, Int((Double(bitmap.height) * scale).rounded()))
            var pixels = [UInt8](repeating: 255, count: width * height)
            for y in 0 ..< height {
                let sourceY = (Double(y) + 0.5) / scale - 0.5
                for x in 0 ..< width {
                    let sourceX = (Double(x) + 0.5) / scale - 0.5
                    pixels[y * width + x] = sample(bitmap, x: sourceX, y: sourceY)
                }
            }
            return Result(
                bitmap: GrayBitmap(
                    pixels: pixels, width: width, height: height,
                    dpi: bitmap.dpi * scale,
                ),
                scale: scale,
            )
        }

        private static func sample(_ bitmap: GrayBitmap, x: Double, y: Double) -> UInt8 {
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let fx = x - Double(x0), fy = y - Double(y0)
            let x1 = min(bitmap.width - 1, max(0, x0 + 1))
            let y1 = min(bitmap.height - 1, max(0, y0 + 1))
            let cx0 = min(bitmap.width - 1, max(0, x0))
            let cy0 = min(bitmap.height - 1, max(0, y0))
            let top = Double(bitmap[cx0, cy0]) * (1 - fx) + Double(bitmap[x1, cy0]) * fx
            let bottom = Double(bitmap[cx0, y1]) * (1 - fx) + Double(bitmap[x1, y1]) * fx
            let value = top * (1 - fy) + bottom * fy
            return UInt8(max(0, min(255, value.rounded())))
        }
    }
#endif
