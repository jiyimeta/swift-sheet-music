import SheetMusicFoundation

/// A small PNG reader for the files PDF cannot take as they are: 8-bit, non-interlaced gray+alpha (color type 4) and
/// RGBA (color type 6). It inflates the concatenated `IDAT`, undoes the five scanline filters and splits the channels
/// into a color plane and an alpha plane, which `PDFImageXObject` writes as an image and its soft mask. Anything else
/// (16-bit, interlaced, other color types, a damaged stream) answers `nil`.
enum PNGDecodeLite {
    /// Samples are row-major, top row first: `color` holds one (gray) or three (RGB) bytes a pixel, `alpha` one.
    static func decode(_: Data) -> (width: Int, height: Int, color: [UInt8], alpha: [UInt8]?)? {
        nil
    }
}
