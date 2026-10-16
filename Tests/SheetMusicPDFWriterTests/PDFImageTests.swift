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
        let channels = Self.channels(colorType)
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

    private static func channels(_ colorType: UInt8) -> Int {
        switch colorType {
        case 2: 3
        case 4: 2
        case 6: 4
        default: 1
        }
    }

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// A sample byte that differs with the pixel and the channel, so no filter can pass by accident.
    static func sample(_ x: Int, _ y: Int, _ channel: Int) -> UInt8 {
        UInt8((x * 67 + y * 131 + channel * 29) % 256)
    }

    /// Scanlines of unfiltered pixel bytes, each behind a filter byte (`filters[row % filters.count]`) and encoded
    /// with that filter, as a PNG stores them.
    static func filtered(_ rows: [[UInt8]], bytesPerPixel: Int, filters: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: rows.first?.count ?? 0)
        for (index, row) in rows.enumerated() {
            let filter = filters[index % filters.count]
            output.append(filter)
            for position in row.indices {
                let left = position >= bytesPerPixel ? Int(row[position - bytesPerPixel]) : 0
                let up = Int(previous[position])
                let upLeft = position >= bytesPerPixel ? Int(previous[position - bytesPerPixel]) : 0
                let predicted: Int
                switch filter {
                case 1: predicted = left
                case 2: predicted = up
                case 3: predicted = (left + up) / 2
                case 4: predicted = paeth(left, up, upLeft)
                default: predicted = 0
                }
                output.append(row[position] &- UInt8(truncatingIfNeeded: predicted))
            }
            previous = row
        }
        return output
    }

    private static func paeth(_ left: Int, _ up: Int, _ upLeft: Int) -> Int {
        let estimate = left + up - upLeft
        let toLeft = abs(estimate - left)
        let toUp = abs(estimate - up)
        let toUpLeft = abs(estimate - upLeft)
        if toLeft <= toUp, toLeft <= toUpLeft { return left }
        return toUp <= toUpLeft ? up : upLeft
    }

    /// An RGBA file whose `IDAT` chunk claims 0xFFFFFFF0 bytes: a length that is negative as a 32-bit `Int`.
    static func pngWithHostileIDATLength() -> Data {
        var bytes = signature
        bytes += chunk("IHDR", bigEndian(4) + bigEndian(4) + [8, 6, 0, 0, 0])
        bytes += [0xFF, 0xFF, 0xFF, 0xF0] + Array("IDAT".utf8) + [0x78, 0x9C, 0, 0, 0, 0, 0, 0]
        return Data(bytes)
    }

    /// An RGBA file that claims 0x7FFFFFFF x 0x7FFFFFFF pixels behind a tiny, well-formed `IDAT`.
    static func pngWithHugeDimensions() throws -> Data {
        var bytes = signature
        bytes += chunk("IHDR", bigEndian(0x7FFF_FFFF) + bigEndian(0x7FFF_FFFF) + [8, 6, 0, 0, 0])
        bytes += try chunk("IDAT", [UInt8](PDFFlate.encode(Data([0, 0, 0, 0, 0]))))
        bytes += chunk("IEND", [])
        return Data(bytes)
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

    /// The real fixtures on a page, written to `.build/w7/img.pdf` to be looked at; runs with `SM_KEEP_ARTIFACTS=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SM_KEEP_ARTIFACTS"] == "1"))
    func realFixturesAreWrittenForALook() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("Tests/SheetMusicTests/Resources/own")
        let png = try Data(contentsOf: fixtures.appendingPathComponent("frames-px-rgb.png"))
        let jpeg = try Data(contentsOf: fixtures.appendingPathComponent("frames-photo.jpg"))

        let file = try Self.write([
            .setColor(argb: 0xFFDD_DDDD), .fillRect(x: 5, y: 5, w: 90, h: 140), .setColor(argb: 0xFF00_0000),
            .drawImage(data: png, x: 10, y: 10, w: 40, h: 40),
            .drawImage(data: jpeg, x: 10, y: 60, w: 80, h: 60),
        ])
        let output = root.appendingPathComponent(".build/w7", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try file.write(to: output.appendingPathComponent("img.pdf"))

        #expect(Self.count(of: "/Subtype /Image", in: Self.text(of: file)) == 2)
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

    // MARK: - PNG with alpha

    /// The image XObjects of a file in the order written, each with its dictionary text and its stream payload.
    private static func imageObjects(in file: Data) -> [(dictionary: String, payload: Data)] {
        let bytes = [UInt8](file)
        let marker = Array("/Subtype /Image".utf8)
        let stream = Array("stream\n".utf8)
        var found: [(dictionary: String, payload: Data)] = []
        var from = 0
        while let hit = bytes[from...].firstRange(of: marker),
              let start = bytes[hit.upperBound...].firstRange(of: stream)
        {
            let dictionary = String(bytes: bytes[hit.lowerBound ..< start.lowerBound], encoding: .isoLatin1) ?? ""
            let length = dictionary.components(separatedBy: "/Length ").dropFirst().first
                .flatMap { text in Int(text.prefix { $0.isNumber }) } ?? 0
            let end = min(start.upperBound + length, bytes.count)
            found.append((dictionary: dictionary, payload: Data(bytes[start.upperBound ..< end])))
            from = end
        }
        return found
    }

    /// Row-major pixel bytes: `channels` samples a pixel from `value(x, y, channel)`.
    private static func pixelRows(
        width: Int, height: Int, channels: Int, value: (Int, Int, Int) -> UInt8,
    ) -> [[UInt8]] {
        (0 ..< height).map { y in
            (0 ..< width).flatMap { x in (0 ..< channels).map { value(x, y, $0) } }
        }
    }

    /// The samples of one plane: channels `wanted` of every pixel, in row order.
    private static func plane(_ rows: [[UInt8]], channels: Int, wanted: Range<Int>) -> [UInt8] {
        rows.flatMap { row in
            row.indices.filter { wanted.contains($0 % channels) }.map { row[$0] }
        }
    }

    /// Task 1's generator rule: pixels with `x <= 4` are translucent (alpha 90), the rest opaque.
    @Test func rgbaSplitsIntoColorAndMask() throws {
        let rows = Self.pixelRows(width: 40, height: 20, channels: 4) { x, y, channel in
            channel == 3 ? (x <= 4 ? 90 : 255) : ImageFixtures.sample(x, y, channel)
        }
        let raw = ImageFixtures.filtered(rows, bytesPerPixel: 4, filters: [0])
        let png = try ImageFixtures.png(width: 40, height: 20, colorType: 6, rows: raw)
        let file = try Self.write([Self.draw(png.file)])
        let objects = Self.imageObjects(in: file)

        #expect(Self.count(of: "/Subtype /Image", in: Self.text(of: file)) == 2)
        #expect(objects.count == 2)
        let color = try #require(objects.first { $0.dictionary.contains("/SMask ") })
        let mask = try #require(objects.first { !$0.dictionary.contains("/SMask ") })
        #expect(color.dictionary.contains("/ColorSpace /DeviceRGB"))
        #expect(color.dictionary.contains("/Filter /FlateDecode"))
        #expect(!color.dictionary.contains("/Predictor"))
        #expect(mask.dictionary.contains("/ColorSpace /DeviceGray"))
        #expect(mask.dictionary.contains("/Width 40"))
        #expect(mask.dictionary.contains("/Height 20"))
        #expect(mask.dictionary.contains("/BitsPerComponent 8"))
        let alpha = try [UInt8](PDFFlate.decode(mask.payload, limit: 1 << 20))
        let rgb = try [UInt8](PDFFlate.decode(color.payload, limit: 1 << 20))
        #expect(alpha == Self.plane(rows, channels: 4, wanted: 3 ..< 4))
        #expect(alpha.prefix(6) == [90, 90, 90, 90, 90, 255])
        #expect(rgb == Self.plane(rows, channels: 4, wanted: 0 ..< 3))
    }

    /// One filter per row — None, Sub, Up, Average, Paeth — over a 4 x 5 RGBA picture.
    @Test func allFiveFiltersUnfilter() throws {
        let rows = Self.pixelRows(width: 4, height: 5, channels: 4) { ImageFixtures.sample($0, $1, $2) }
        let raw = ImageFixtures.filtered(rows, bytesPerPixel: 4, filters: [0, 1, 2, 3, 4])
        let png = try ImageFixtures.png(width: 4, height: 5, colorType: 6, rows: raw)

        let decoded = try #require(PNGDecodeLite.decode(png.file))

        #expect(decoded.width == 4)
        #expect(decoded.height == 5)
        #expect(decoded.color == Self.plane(rows, channels: 4, wanted: 0 ..< 3))
        #expect(decoded.alpha == Self.plane(rows, channels: 4, wanted: 3 ..< 4))
    }

    @Test func grayAlpha() throws {
        let rows = Self.pixelRows(width: 3, height: 2, channels: 2) { x, y, channel in
            channel == 0 ? ImageFixtures.sample(x, y, 0) : UInt8(250 - x * 50 - y * 3)
        }
        let raw = ImageFixtures.filtered(rows, bytesPerPixel: 2, filters: [2, 1])
        let png = try ImageFixtures.png(width: 3, height: 2, colorType: 4, rows: raw)
        let gray = Self.plane(rows, channels: 2, wanted: 0 ..< 1)
        let alpha = Self.plane(rows, channels: 2, wanted: 1 ..< 2)

        let decoded = try #require(PNGDecodeLite.decode(png.file))
        let file = try Self.write([Self.draw(png.file)])
        let objects = Self.imageObjects(in: file)

        #expect(decoded.color == gray)
        #expect(decoded.alpha == alpha)
        #expect(objects.count == 2)
        let color = try #require(objects.first { $0.dictionary.contains("/SMask ") })
        let mask = try #require(objects.first { !$0.dictionary.contains("/SMask ") })
        #expect(color.dictionary.contains("/ColorSpace /DeviceGray"))
        #expect(mask.dictionary.contains("/ColorSpace /DeviceGray"))
        #expect(try [UInt8](PDFFlate.decode(color.payload, limit: 1 << 20)) == gray)
        #expect(try [UInt8](PDFFlate.decode(mask.payload, limit: 1 << 20)) == alpha)
    }

    /// 16-bit RGBA has no soft-mask path here: nothing is decoded and nothing is embedded.
    @Test func sixteenBitIsNil() throws {
        let png = try ImageFixtures.png(width: 4, height: 4, colorType: 6, bitDepth: 16)

        #expect(PNGDecodeLite.decode(png.file) == nil)
        #expect(PDFImageXObject.make(from: png.file) == nil)
    }

    /// A chunk length of 0xFFFFFFF0 is negative as a 32-bit `Int`: it must be refused, not sliced.
    @Test func hostileChunkLengthIsNil() {
        let file = ImageFixtures.pngWithHostileIDATLength()

        #expect(PDFImageXObject.make(from: file) == nil)
        #expect(PNGDecodeLite.decode(file) == nil)
    }

    /// Dimensions whose pixel count overflows any `Int` row arithmetic are refused before anything is allocated.
    @Test func hugeDimensionsAreNil() throws {
        let file = try ImageFixtures.pngWithHugeDimensions()

        #expect(PNGDecodeLite.decode(file) == nil)
        #expect(PDFImageXObject.make(from: file) == nil)
    }
}
