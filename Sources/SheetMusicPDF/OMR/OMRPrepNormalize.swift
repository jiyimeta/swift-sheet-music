import Foundation

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

    /// The most pixels a normalized page may have. A real page lands far below it — a 300 dpi letter page at the
    /// canonical scale is about 9 MP, and a 72 dpi scan scaled up twice about 2 MP — so a page over it means the staff
    /// spacing it was handed is a misread. A spacing of a pixel or less asked for a page dozens to thousands of times
    /// the original's area: the allocation of 1–5 GB trapped the app (folino 2.4.1–2.5.0, Crashlytics 8e17057a), and a
    /// scale large enough to be infinite trapped converting the size to `Int`. Such a page is not normalized, so the
    /// detector reads nothing from it and says why.
    static let maximumPixelCount = 64_000_000

    static func normalize(
        _ bitmap: GrayBitmap, staffSpacingPx: Double, targetStaffSpacePx: Double,
    ) -> Result? {
        guard staffSpacingPx > 0, targetStaffSpacePx > 0 else { return nil }
        let scale = targetStaffSpacePx / staffSpacingPx
        guard scale != 1.0 else { return Result(bitmap: bitmap, scale: 1.0) }
        // Sized in `Double` and checked before anything is converted or allocated.
        let scaledWidth = max(1, (Double(bitmap.width) * scale).rounded())
        let scaledHeight = max(1, (Double(bitmap.height) * scale).rounded())
        guard scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth * scaledHeight <= Double(maximumPixelCount)
        else { return nil }
        let width = Int(scaledWidth)
        let height = Int(scaledHeight)
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
