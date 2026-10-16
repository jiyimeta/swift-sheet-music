import SheetMusicFoundation
import SheetMusicPDFSyntax

/// A small PNG reader for the files PDF cannot take as they are: 8-bit, non-interlaced gray+alpha (color type 4) and
/// RGBA (color type 6). It inflates the concatenated `IDAT`, undoes the five scanline filters and splits the channels
/// into a color plane and an alpha plane, which `PDFImageXObject` writes as an image and its soft mask. Anything else
/// (16-bit, interlaced, other color types, a damaged stream, sizes that overflow) answers `nil`.
enum PNGDecodeLite {
    /// The most inflated bytes (filter bytes included) a picture may need: bigger files are refused, not allocated.
    private static let maxInflatedBytes = 1 << 28

    /// Samples are row-major, top row first: `color` holds one (gray) or three (RGB) bytes a pixel, `alpha` one.
    static func decode(_ file: Data) -> (width: Int, height: Int, color: [UInt8], alpha: [UInt8]?)? {
        let header = [UInt8](file.prefix(29))
        guard header.count == 29, Array(header[12 ..< 16]) == Array("IHDR".utf8),
              header[24] == 8, header[28] == 0, header[25] == 4 || header[25] == 6,
              let width = dimension(header, 16), let height = dimension(header, 20)
        else { return nil }
        let channels = header[25] == 6 ? 4 : 2
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: channels)
        let (lineBytes, lineOverflow) = rowBytes.addingReportingOverflow(1)
        let (total, totalOverflow) = lineBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !lineOverflow, !totalOverflow, total <= maxInflatedBytes,
              let chunks = PNGChunks(file),
              let inflated = try? PDFFlate.decode(chunks.imageData, limit: total), inflated.count == total,
              let pixels = unfilter([UInt8](inflated), rowBytes: rowBytes, height: height, bytesPerPixel: channels)
        else { return nil }
        var color: [UInt8] = []
        var alpha: [UInt8] = []
        color.reserveCapacity(width * height * (channels - 1))
        alpha.reserveCapacity(width * height)
        for start in stride(from: 0, to: pixels.count, by: channels) {
            color += pixels[start ..< start + channels - 1]
            alpha.append(pixels[start + channels - 1])
        }
        return (width, height, color, alpha)
    }

    /// A big-endian 32-bit field as a positive `Int`, or nil when it is zero or does not fit.
    private static func dimension(_ bytes: [UInt8], _ offset: Int) -> Int? {
        let value = bytes[offset ..< offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let size = Int(exactly: value), size > 0 else { return nil }
        return size
    }

    /// The pixel bytes of `height` scanlines of `rowBytes` bytes, each behind a filter byte; nil for an unknown filter.
    private static func unfilter(_ raw: [UInt8], rowBytes: Int, height: Int, bytesPerPixel: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        for row in 0 ..< height {
            let source = row * (rowBytes + 1)
            let filter = raw[source]
            guard filter <= 4 else { return nil }
            let target = row * rowBytes
            for index in 0 ..< rowBytes {
                let left = index >= bytesPerPixel ? Int(pixels[target + index - bytesPerPixel]) : 0
                let up = row > 0 ? Int(pixels[target - rowBytes + index]) : 0
                let upLeft = row > 0 && index >= bytesPerPixel
                    ? Int(pixels[target - rowBytes + index - bytesPerPixel]) : 0
                let predicted: Int
                switch filter {
                case 1: predicted = left
                case 2: predicted = up
                case 3: predicted = (left + up) / 2
                case 4: predicted = paeth(left, up, upLeft)
                default: predicted = 0
                }
                pixels[target + index] = raw[source + 1 + index] &+ UInt8(truncatingIfNeeded: predicted)
            }
        }
        return pixels
    }

    private static func paeth(_ left: Int, _ up: Int, _ upLeft: Int) -> Int {
        let estimate = left + up - upLeft
        let toLeft = abs(estimate - left)
        let toUp = abs(estimate - up)
        let toUpLeft = abs(estimate - upLeft)
        if toLeft <= toUp, toLeft <= toUpLeft { return left }
        return toUp <= toUpLeft ? up : upLeft
    }
}
