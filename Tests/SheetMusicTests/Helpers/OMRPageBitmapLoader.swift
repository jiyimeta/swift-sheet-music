#if !os(Android)
    import CoreGraphics
    import Foundation
    import ImageIO
    @testable import SheetMusicPDF

    /// PNG → `GrayBitmap`, and the ONE sanctioned way a sweep touches a
    /// page image.
    ///
    /// A previous dataset sweep here consumed 24GB and took the machine
    /// down: the harness lacked `autoreleasepool`, so CoreGraphics'
    /// temporaries lived until the test returned and 2208 renders' worth
    /// of them were alive at once. Peak is set by the LARGEST SINGLE PAGE
    /// (~18MB grayscale for A4 at 400dpi), not by dataset size, so a
    /// sweep holding one page at a time has a flat ceiling however big
    /// the dataset gets.
    ///
    /// The pool is owned HERE, not at the call site, precisely so that it
    /// cannot be forgotten at the call site: the CG-backed buffer is
    /// copied into the plain `[UInt8]` inside the pool and dies with it.
    /// Sweeps must not call `decode` directly — that is why it is
    /// private.
    enum OMRPageBitmapLoader {
        static func withPageBitmap<T>(
            url: URL, dpi: Double, _ body: (GrayBitmap) throws -> T,
        ) throws -> T {
            try autoreleasepool {
                let bitmap = try decode(url: url, dpi: dpi)
                return try body(bitmap)
            }
        }

        /// Peak resident set size of this process, in MB, so that a leak
        /// surfaces as a number in a `[SUMMARY]` line rather than as a
        /// dead machine. `ru_maxrss` is in BYTES on Darwin (it is
        /// kilobytes on Linux, which this Apple-only helper never runs
        /// on).
        static func peakResidentMB() -> Int {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
            return Int(usage.ru_maxrss) / (1024 * 1024)
        }

        private static func decode(url: URL, dpi: Double) throws -> GrayBitmap {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw loaderError(1, "cannot decode \(url.path)")
            }
            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 255, count: width * height)
            let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue,
                ) else { return false }
                context.draw(
                    image, in: CGRect(x: 0, y: 0, width: width, height: height),
                )
                return true
            }
            guard ok else { throw loaderError(2, "cannot render \(url.path)") }
            return GrayBitmap(pixels: pixels, width: width, height: height, dpi: dpi)
        }

        private static func loaderError(_ code: Int, _ message: String) -> NSError {
            NSError(
                domain: "OMRPageBitmapLoader", code: code,
                userInfo: [NSLocalizedDescriptionKey: message],
            )
        }
    }
#endif
