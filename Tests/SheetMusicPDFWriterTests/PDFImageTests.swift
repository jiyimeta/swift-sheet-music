import Foundation
@testable import SheetMusicBridgeCore
@testable import SheetMusicPDF
import SheetMusicPDFSyntax
@testable import SheetMusicPDFWriter
import Testing

/// PNG and JPEG files built in the test: the writer only reads headers (`ImageSniffer`) and never decodes, so a PNG
/// needs well-formed chunk framing and a real zlib `IDAT`, and a JPEG only its markers.
enum ImageFixtures {
    /// A PNG file, and the concatenated payload of its `IDAT` chunks.
    struct PNG {
        let file: Data
        let idat: Data
    }

    /// SOI, an SOF0 frame header for a 40 x 20 picture with three components, EOI — all `ImageSniffer` reads.
    static let jpegBytes = Data([
        0xFF, 0xD8,
        0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x14, 0x00, 0x28, 0x03,
        0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
        0xFF, 0xD9,
    ])

    /// The same, one pixel taller: a different picture.
    static let otherJPEGBytes = Data([
        0xFF, 0xD8,
        0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x15, 0x00, 0x28, 0x03,
        0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
        0xFF, 0xD9,
    ])

    /// - Parameters:
    ///   - rows: the raw scanlines, each behind its filter byte; sample bytes derived from the row and column when nil.
    ///   - idatChunks: how many `IDAT` chunks the zlib stream is split over (one or two).
    static func png(
        width: Int, height: Int, colorType: UInt8, bitDepth: UInt8 = 8, interlace: UInt8 = 0,
        palette: [UInt8] = [], rows: [UInt8]? = nil, idatChunks: Int = 1,
    ) throws -> PNG {
        let channels = colorType == 2 ? 3 : 1
        let rowBytes = width * channels * max(Int(bitDepth) / 8, 1)
        let raw: [UInt8] = rows ?? (0 ..< height).flatMap { row -> [UInt8] in
            [UInt8(0)] + (0 ..< rowBytes).map { UInt8(truncatingIfNeeded: row * 31 + $0 * 7) }
        }
        let idat = try PDFFlate.encode(Data(raw))
        let split = idatChunks > 1 ? idat.count / 2 : idat.count
        let payloads = [[UInt8](idat.prefix(split)), [UInt8](idat.dropFirst(split))].filter { !$0.isEmpty }
        let header = bigEndian(width) + bigEndian(height) + [bitDepth, colorType, 0, 0, interlace]
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += chunk("IHDR", header)
        if !palette.isEmpty { bytes += chunk("PLTE", palette) }
        for payload in payloads {
            bytes += chunk("IDAT", payload)
        }
        bytes += chunk("IEND", [])
        return PNG(file: Data(bytes), idat: idat)
    }

    /// Length, type, body, CRC. The CRC is zero: nothing here checks it.
    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        bigEndian(body.count) + Array(type.utf8) + body + [0, 0, 0, 0]
    }

    private static func bigEndian(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

/// A picture on a page (`.drawImage`) written as an image XObject: JPEG as it is, an 8-bit non-interlaced gray, RGB or
/// palette PNG through its own deflate stream and predictors, anything else not at all.
struct PDFImageTests {
    private static func write(_ commands: [DrawCommand]) throws -> Data {
        let page = EncodablePage(widthMM: 100, heightMM: 150, commands: commands)
        return try ScorePDFWriter.write([page], fonts: WriterFixtures.fonts(), title: nil)
    }

    private static func draw(_ data: Data, x: Double = 20, y: Double = 30) -> DrawCommand {
        .drawImage(data: data, x: x, y: y, w: 10, h: 5)
    }

    private static func text(of file: Data) -> String {
        // Latin-1 maps every byte to a character, so the binary streams cannot make the conversion fail.
        String(data: file, encoding: .isoLatin1) ?? ""
    }

    private static func contains(_ file: Data, _ bytes: Data) -> Bool {
        [UInt8](file).firstRange(of: [UInt8](bytes)) != nil
    }

    private static func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func jpegIsPassedThrough() throws {
        let file = try Self.write([Self.draw(ImageFixtures.jpegBytes)])
        let text = Self.text(of: file)

        #expect(text.contains("/Subtype /Image"))
        #expect(text.contains("/Width 40"))
        #expect(text.contains("/Height 20"))
        #expect(text.contains("/Filter /DCTDecode"))
        #expect(text.contains("/ColorSpace /DeviceRGB"))
        #expect(Self.contains(file, ImageFixtures.jpegBytes))
    }

    @Test func opaquePNGUsesPredictors() throws {
        let png = try ImageFixtures.png(width: 40, height: 20, colorType: 2, idatChunks: 2)
        let file = try Self.write([Self.draw(png.file)])
        let text = Self.text(of: file)

        #expect(text.contains("/Subtype /Image"))
        #expect(text.contains("/Width 40"))
        #expect(text.contains("/Height 20"))
        #expect(text.contains("/ColorSpace /DeviceRGB"))
        #expect(text.contains("/BitsPerComponent 8"))
        #expect(text.contains("/Predictor 15"))
        #expect(text.contains("/Colors 3"))
        #expect(text.contains("/Columns 40"))
        // The two IDAT chunks, concatenated, are the stream: the pixels are neither decoded nor deflated again.
        #expect(Self.contains(file, png.idat))
    }

    @Test func paletteBecomesIndexed() throws {
        let palette: [UInt8] = [0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF]
        let png = try ImageFixtures.png(width: 2, height: 2, colorType: 3, palette: palette, rows: [0, 0, 1, 0, 1, 0])
        let text = try Self.text(of: Self.write([Self.draw(png.file)]))

        #expect(text.contains("/Subtype /Image"))
        #expect(text.contains("/Indexed /DeviceRGB 1 <"))
        #expect(text.uppercased().contains("<FF00000000FF>"))
        #expect(text.contains("/Predictor 15"))
        #expect(text.contains("/Colors 1"))
        #expect(text.contains("/Columns 2"))
    }

    @Test func sameImageIsEmbeddedOnce() throws {
        let png = try ImageFixtures.png(width: 40, height: 20, colorType: 2)
        let once = try Self.text(of: Self.write([Self.draw(png.file)]))
        let twice = try Self.text(of: Self.write([Self.draw(png.file), Self.draw(png.file, x: 60, y: 90)]))
        let jpeg = ImageFixtures.jpegBytes
        let different = try Self.text(of: Self.write([
            Self.draw(jpeg), Self.draw(ImageFixtures.otherJPEGBytes), Self.draw(jpeg, x: 60, y: 90),
        ]))

        #expect(Self.count(of: "/Subtype /Image", in: once) == 1)
        #expect(Self.count(of: "/Subtype /Image", in: twice) == 1)
        #expect(Self.count(of: "/Subtype /Image", in: different) == 2)
    }

    @Test func unreadablePayloadDrawsNothing() throws {
        let junk = Data("not an image at all".utf8)
        let file = try Self.write([Self.draw(junk), Self.draw(Data())])
        let reader = try #require(PDFReaderDocument(data: file))

        #expect(reader.pageCount == 1)
        #expect(!Self.text(of: file).contains("/Subtype /Image"))
        #expect(PDFImageXObject.make(from: junk) == nil)
    }

    @Test func interlacedAndSixteenBitAreSkipped() throws {
        let interlaced = try ImageFixtures.png(width: 40, height: 20, colorType: 2, interlace: 1)
        let sixteenBit = try ImageFixtures.png(width: 40, height: 20, colorType: 2, bitDepth: 16)
        let file = try Self.write([Self.draw(interlaced.file), Self.draw(sixteenBit.file)])
        let reader = try #require(PDFReaderDocument(data: file))

        #expect(reader.pageCount == 1)
        #expect(!Self.text(of: file).contains("/Subtype /Image"))
        #expect(PDFImageXObject.make(from: interlaced.file) == nil)
        #expect(PDFImageXObject.make(from: sixteenBit.file) == nil)
    }
}
