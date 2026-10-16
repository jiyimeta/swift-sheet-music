import SheetMusicFoundation
import SheetMusicPDFSyntax

/// A small PNG reader for the files PDF cannot take as they are: 8-bit, non-interlaced gray+alpha (color type 4) and
/// RGBA (color type 6). It inflates the concatenated `IDAT`, undoes the five scanline filters and splits the channels
/// into a color plane and an alpha plane, which `PDFImageXObject` writes as an image and its soft mask. Anything else
/// (16-bit, interlaced, other color types, a damaged stream, sizes that overflow) answers `nil`.
///
/// Memory: the scanlines are inflated into one buffer and unfiltered in place there, the planes are copied out of it,
/// and it is released when `decode` returns — before the caller deflates the planes again. So at most the inflated
/// picture and its two planes (about twice `maxInflatedBytes`) are alive at once.
enum PNGDecodeLite {
    /// The most inflated bytes (filter bytes included) a picture may need — 64 MiB, a 4096 × 4096 RGBA picture less
    /// its filter bytes: bigger files are refused, not allocated, and draw nothing in the PDF.
    private static let maxInflatedBytes = 1 << 26

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
              let scanlines = unfilteredScanlines(
                  file, total: total, rowBytes: rowBytes, height: height, bytesPerPixel: channels,
              )
        else { return nil }
        let planes = split(scanlines, rowBytes: rowBytes, height: height, channels: channels)
        return (width, height, planes.color, planes.alpha)
    }

    /// The `IDAT` stream inflated and unfiltered in place: `height` scanlines of `rowBytes` pixel bytes, each still
    /// behind its filter byte. `nil` for a damaged stream, a wrong length or an unknown filter.
    private static func unfilteredScanlines(
        _ file: Data, total: Int, rowBytes: Int, height: Int, bytesPerPixel: Int,
    ) -> Data? {
        guard let chunks = PNGChunks(file),
              var scanlines = try? PDFFlate.decode(chunks.imageData, limit: total), scanlines.count == total
        else { return nil }
        let unfiltered = scanlines.withUnsafeMutableBytes {
            unfilter($0, rowBytes: rowBytes, height: height, bytesPerPixel: bytesPerPixel)
        }
        return unfiltered ? scanlines : nil
    }

    /// The pixel bytes of unfiltered `scanlines` split into the color samples and the alpha samples.
    private static func split(
        _ scanlines: Data, rowBytes: Int, height: Int, channels: Int,
    ) -> (color: [UInt8], alpha: [UInt8]) {
        let pixelCount = rowBytes / channels * height
        var color: [UInt8] = []
        var alpha: [UInt8] = []
        color.reserveCapacity(pixelCount * (channels - 1))
        alpha.reserveCapacity(pixelCount)
        scanlines.withUnsafeBytes { raw in
            for row in 0 ..< height {
                let start = row * (rowBytes + 1) + 1
                for pixel in stride(from: start, to: start + rowBytes, by: channels) {
                    color.append(contentsOf: raw[pixel ..< pixel + channels - 1])
                    alpha.append(raw[pixel + channels - 1])
                }
            }
        }
        return (color, alpha)
    }

    /// A big-endian 32-bit field as a positive `Int`, or nil when it is zero or does not fit.
    private static func dimension(_ bytes: [UInt8], _ offset: Int) -> Int? {
        let value = bytes[offset ..< offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let size = Int(exactly: value), size > 0 else { return nil }
        return size
    }

    /// Undoes the filters of `height` scanlines of `rowBytes` bytes, each behind a filter byte, in place: a byte's
    /// left, up and up-left neighbors are reconstructed before it is, so they can be read from the same buffer.
    /// `false` for an unknown filter.
    private static func unfilter(
        _ raw: UnsafeMutableRawBufferPointer, rowBytes: Int, height: Int, bytesPerPixel: Int,
    ) -> Bool {
        let lineBytes = rowBytes + 1
        for row in 0 ..< height {
            let source = row * lineBytes
            let filter = raw[source]
            guard filter <= 4 else { return false }
            let target = source + 1
            for index in 0 ..< rowBytes {
                let left = index >= bytesPerPixel ? Int(raw[target + index - bytesPerPixel]) : 0
                let up = row > 0 ? Int(raw[target - lineBytes + index]) : 0
                let upLeft = row > 0 && index >= bytesPerPixel
                    ? Int(raw[target - lineBytes + index - bytesPerPixel]) : 0
                let predicted: Int
                switch filter {
                case 1: predicted = left
                case 2: predicted = up
                case 3: predicted = (left + up) / 2
                case 4: predicted = paeth(left, up, upLeft)
                default: predicted = 0
                }
                raw[target + index] &+= UInt8(truncatingIfNeeded: predicted)
            }
        }
        return true
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
