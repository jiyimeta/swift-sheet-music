import SheetMusicCore
import SheetMusicFoundation
import SheetMusicPDFSyntax

/// A picture as a PDF image XObject: the stream's dictionary entries and its payload, read from the file's header
/// alone (`ImageSniffer`); only a PNG with alpha is decoded (`PNGDecodeLite`). A JPEG goes in as it is (`DCTDecode`);
/// a PNG whose pixels PDF can unpredict itself (8-bit gray, RGB or palette, not interlaced) goes in as its
/// concatenated `IDAT` bytes (`FlateDecode` with PNG predictors); an RGBA or gray+alpha one as a color image and a
/// soft mask. Anything else has no XObject: `make` returns `nil` and the page draws nothing for it.
///
/// A PNG's `tRNS` (a palette's or a key color's transparency), gamma and ICC chunks are ignored: the colors are
/// written as device colors, opaque.
struct PDFImageXObject {
    /// The stream dictionary's entries, without `<< >>` and without `/Length`: `/Type`, `/Subtype`, size, color space,
    /// bits, and the filter (and its parameters) the payload is already in.
    let dictionary: String
    /// The stream's payload, written as it is — never compressed again.
    let data: Data
    /// The alpha plane of a PNG with alpha: a second image the writer emits first and this one names in `/SMask`.
    var softMask: SoftMask?

    /// An 8-bit `/DeviceGray` image used as a soft mask: its dictionary entries (without `/Length`) and its payload.
    struct SoftMask {
        let dictionary: String
        let data: Data
    }

    /// The XObject for a PNG or JPEG file, or `nil` when it is neither, or its pixels are not ones PDF reads directly.
    static func make(from data: Data) -> PDFImageXObject? {
        guard let info = ImageSniffer.sniff(data) else { return nil }
        switch info.format {
        case .jpeg: return jpeg(data, info)
        case .png: return png(data, info)
        }
    }

    private static func entries(_ info: ImageInfo, colorSpace: String) -> String {
        "/Type /XObject /Subtype /Image /Width \(info.width) /Height \(info.height) /ColorSpace \(colorSpace) "
            + "/BitsPerComponent 8"
    }

    /// The file itself, in the device color space its component count names. A CMYK file that carries an Adobe marker
    /// stores inverted values, which `/Decode` turns back.
    private static func jpeg(_ data: Data, _ info: ImageInfo) -> PDFImageXObject? {
        let colorSpace: String
        var decode = ""
        switch info.jpegComponents {
        case 1: colorSpace = "/DeviceGray"
        case 3: colorSpace = "/DeviceRGB"
        case 4:
            colorSpace = "/DeviceCMYK"
            if info.jpegHasAdobeMarker { decode = " /Decode [1 0 1 0 1 0 1 0]" }
        default: return nil
        }
        return PDFImageXObject(
            dictionary: entries(info, colorSpace: colorSpace) + decode + " /Filter /DCTDecode", data: data,
        )
    }

    /// Gray, RGB or palette at 8 bits, not interlaced: the `IDAT` payload is already a zlib stream of predicted rows,
    /// which is what `/FlateDecode` with `/Predictor 15` reads.
    private static func png(_ data: Data, _ info: ImageInfo) -> PDFImageXObject? {
        guard let png = info.png, !png.isInterlaced, png.bitDepth == 8 else { return nil }
        if png.colorType == 4 || png.colorType == 6 { return alphaPNG(data, info, hasColor: png.colorType == 6) }
        guard [0, 2, 3].contains(png.colorType), let chunks = PNGChunks(data) else { return nil }
        let colorSpace: String
        switch png.colorType {
        case 0: colorSpace = "/DeviceGray"
        case 2: colorSpace = "/DeviceRGB"
        default:
            guard let palette = chunks.palette else { return nil }
            colorSpace = "[/Indexed /DeviceRGB \(palette.count / 3 - 1) <\(hex(palette))>]"
        }
        let colors = png.colorType == 2 ? 3 : 1
        let parameters = "/Predictor 15 /Colors \(colors) /BitsPerComponent 8 /Columns \(info.width)"
        let filter = " /Filter /FlateDecode /DecodeParms << \(parameters) >>"
        return PDFImageXObject(dictionary: entries(info, colorSpace: colorSpace) + filter, data: chunks.imageData)
    }

    /// Gray+alpha or RGBA: the color plane and the alpha plane, each deflated again with no predictor; the alpha plane
    /// becomes the color image's soft mask.
    private static func alphaPNG(_ data: Data, _ info: ImageInfo, hasColor: Bool) -> PDFImageXObject? {
        guard let decoded = PNGDecodeLite.decode(data), let alpha = decoded.alpha,
              let color = try? PDFFlate.encode(Data(decoded.color)), let mask = try? PDFFlate.encode(Data(alpha))
        else { return nil }
        let filter = " /Filter /FlateDecode"
        let softMask = SoftMask(dictionary: entries(info, colorSpace: "/DeviceGray") + filter, data: mask)
        return PDFImageXObject(
            dictionary: entries(info, colorSpace: hasColor ? "/DeviceRGB" : "/DeviceGray") + filter, data: color,
            softMask: softMask,
        )
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF")
        return String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] })
    }
}

/// The two chunks of a PNG a PDF needs, found by walking the chunk list: the concatenated `IDAT` payloads, and the
/// palette. Nil for a file that ends inside a chunk, has no `IDAT`, or whose palette is not whole RGB triples.
struct PNGChunks {
    let imageData: Data
    let palette: [UInt8]?

    init?(_ file: Data) {
        let bytes = [UInt8](file)
        var image: [UInt8] = []
        var palette: [UInt8]?
        var index = 8
        var sawEnd = false
        while !sawEnd, index + 8 <= bytes.count {
            let declared = bytes[index ..< index + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            // A length read through a 32-bit `Int` can turn negative; a checked conversion refuses it instead.
            guard let length = Int(exactly: declared), length <= bytes.count else { return nil }
            let type = Array(bytes[index + 4 ..< index + 8])
            let body = index + 8
            guard body + length + 4 <= bytes.count else { return nil }
            if type == Array("IDAT".utf8) {
                image += bytes[body ..< body + length]
            } else if type == Array("PLTE".utf8) {
                palette = Array(bytes[body ..< body + length])
            } else if type == Array("IEND".utf8) {
                sawEnd = true
            }
            index = body + length + 4
        }
        guard !image.isEmpty else { return nil }
        if let palette, palette.isEmpty || palette.count % 3 != 0 || palette.count > 768 { return nil }
        imageData = Data(image)
        self.palette = palette
    }
}
