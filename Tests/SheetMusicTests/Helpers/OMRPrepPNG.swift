#if !os(Android)
    import CoreGraphics
    import Foundation
    import ImageIO
    @testable import SheetMusicPDF

    /// The prep export's PNG codec: 8-bit grayscale, no alpha, no color
    /// profile conversion. This file IS the CNN's training input, so the
    /// write path must not resample, dither, or reinterpret bit depth —
    /// the inference path has to reproduce the exact same pixels from the
    /// same page (gate P3d-G2).
    ///
    /// `read` delegates to the same CoreGraphics decode path
    /// `OMRPageBitmapLoader` uses rather than inventing a second one.
    enum OMRPrepPNG {
        static func write(_ bitmap: GrayBitmap, to url: URL) throws {
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil,
            ) else {
                throw pngError(1, "cannot create PNG destination for \(url.path)")
            }
            let image = try makeImage(bitmap)
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw pngError(2, "cannot finalize PNG at \(url.path)")
            }
        }

        static func read(_ url: URL) throws -> GrayBitmap {
            // The dpi passed here is a placeholder: the prep PNG carries no
            // dpi of its own (the JSON side-car's `staff_space_px` is the
            // canonical scale), and this codec's contract is pixels only.
            try OMRPageBitmapLoader.withPageBitmap(url: url, dpi: 0) { $0 }
        }

        /// Copies `bitmap.pixels` into a `Data`-backed provider rather than
        /// wrapping the array's own buffer: a `withUnsafeMutableBytes`
        /// pointer is only valid inside its closure, and `CGImage` retains
        /// the provider well past that — a `bytesNoCopy` provider here
        /// would dangle by the time the image destination reads it.
        private static func makeImage(_ bitmap: GrayBitmap) throws -> CGImage {
            guard let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData) else {
                throw pngError(3, "cannot create data provider")
            }
            guard let image = CGImage(
                width: bitmap.width,
                height: bitmap.height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: bitmap.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent,
            ) else {
                throw pngError(4, "cannot create CGImage from bitmap")
            }
            return image
        }

        private static func pngError(_ code: Int, _ message: String) -> NSError {
            NSError(
                domain: "OMRPrepPNG", code: code,
                userInfo: [NSLocalizedDescriptionKey: message],
            )
        }
    }
#endif
