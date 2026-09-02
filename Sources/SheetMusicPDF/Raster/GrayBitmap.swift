#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// One page as 8-bit grayscale, row-major, y-down from the top-left —
/// the only input the raster front-end takes.
///
/// Deliberately a plain `[UInt8]` rather than a platform image type.
/// Everything under `Raster/` is Foundation-only, so the whole stage
/// cross-compiles to Android for free; and image DECODE is left to the
/// caller, because how a page becomes pixels is a later decision (an
/// image-only PDF hands over an XObject's bytes, not a PNG). Shipping a
/// decoder here would be machinery nothing calls, which in this importer
/// reads as a feature someone should be using.
struct GrayBitmap {
    /// Row-major, `height` rows of `width` bytes. 0 is ink, 255 is paper.
    var pixels: [UInt8]
    var width: Int
    var height: Int
    /// Dots per inch of the raster. This is the only place the pixel and
    /// point coordinate systems meet; see `PageTransform` for the
    /// conversion that uses it.
    var dpi: Double

    init(pixels: [UInt8], width: Int, height: Int, dpi: Double) {
        precondition(
            pixels.count == width * height,
            "pixel count \(pixels.count) must be width \(width) × height \(height)",
        )
        self.pixels = pixels
        self.width = width
        self.height = height
        self.dpi = dpi
    }

    var pointsPerPixel: Double {
        72.0 / dpi
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

/// A binarized page: `true` is ink.
///
/// A separate type from `GrayBitmap` so that a function's signature says
/// which of the two it needs — several passes below are only meaningful
/// on one of them, and the pair are otherwise structurally identical.
struct InkMask {
    var bits: [Bool]
    var width: Int
    var height: Int

    init(bits: [Bool], width: Int, height: Int) {
        precondition(
            bits.count == width * height,
            "bit count \(bits.count) must be width \(width) × height \(height)",
        )
        self.bits = bits
        self.width = width
        self.height = height
    }

    subscript(x: Int, y: Int) -> Bool {
        get { bits[y * width + x] }
        set { bits[y * width + x] = newValue }
    }
}
