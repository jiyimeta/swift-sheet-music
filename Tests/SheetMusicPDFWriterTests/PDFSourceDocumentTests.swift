import Foundation
@testable import SheetMusicPDFWriter
import Testing

struct PDFSourceDocumentTests {
    @Test(arguments: [PDFFixtures.Shape.classic, .objectStreams])
    func `pages are found in order with their numbers`(shape: PDFFixtures.Shape) throws {
        let pages = try PDFSourceDocument(PDFFixtures.make([.init(), .init(), .init()], shape: shape)).pages()
        #expect(pages.map(\.number) == [3, 5, 7])
        #expect(pages.allSatisfy { $0.generation == 0 })
        #expect(pages.map(\.space.displayedSize) == Array(repeating: PDFPageSize(width: 612, height: 792), count: 3))
    }

    @Test(arguments: [PDFFixtures.Shape.classic, .objectStreams])
    func `the newest section remembers its kind and the file's size`(shape: PDFFixtures.Shape) throws {
        let document = try PDFSourceDocument(PDFFixtures.make([.init()], shape: shape))
        #expect(document.lastSectionIsStream == (shape == .objectStreams))
        #expect(document.size >= 5)
        #expect(document.trailer["Root"] == .reference(1, 0))
    }

    @Test func `the crop box and the rotation are read`() throws {
        let file = PDFFixtures.make([.init(extra: " /Rotate 90 /CropBox [10 20 210 120]")])
        let space = try #require(try PDFSourceDocument(file).pages().first).space
        #expect(space == PDFPageSpace(left: 10, bottom: 20, right: 210, top: 120, rotation: 90))
    }

    @Test func `page attributes are inherited and crop boxes are clipped`() throws {
        let file = PDFFixtures.updated(
            PDFFixtures.make([.init(mediaBox: "[0 0 100 200]")]),
            redefining: 2,
            as: "<< /Type /Pages /Kids [3 0 R] /Count 1 /CropBox [-10 20 120 220] /Rotate 270 >>",
        )
        let space = try #require(try PDFSourceDocument(file).pages().first).space
        #expect(space == PDFPageSpace(left: 0, bottom: 20, right: 100, top: 200, rotation: 270))
    }

    @Test func `an object redefined by a later update reads as the later one`() throws {
        let updated = PDFFixtures.updated(
            PDFFixtures.make([.init()]),
            redefining: 3,
            as: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 4 0 R >>",
        )
        let size = try PDFSourceDocument(updated).pages().first?.space.displayedSize
        #expect(size == PDFPageSize(width: 300, height: 400))
    }

    @Test(arguments: [PDFFixtures.Shape.classic, .objectStreams])
    func `slightly shifted object and section offsets recover`(shape: PDFFixtures.Shape) throws {
        var bytes = [UInt8](PDFFixtures.make([.init()], shape: shape))
        bytes.insert(contentsOf: Array("% shifted\n".utf8), at: 9)
        #expect(try PDFSourceDocument(Data(bytes)).pages().count == 1)
    }

    @Test(arguments: [PDFFixtures.Shape.classic, .objectStreams])
    func `an encrypted file is refused as such`(shape: PDFFixtures.Shape) {
        let file = PDFFixtures.make([.init()], shape: shape, trailerExtra: " /Encrypt << /Filter /Standard /V 1 >>")
        #expect(throws: PDFAppendError.encrypted) { try PDFSourceDocument(file) }
    }

    @Test func `bytes that are not a PDF are unreadable`() {
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(Data("hello".utf8)) }
    }

    @Test func `a value written back parses to itself`() throws {
        let source = "<< /A [1 -2.5 (x\\)y) <00FF> /N#20m 3 0 R true null] /B << /C /D >> >>"
        var parser = PDFSourceParser(Array(source.utf8))
        let parsed = parser.parseValue()
        let value = try #require(parsed)
        var reparser = PDFSourceParser(Array(value.serialized.utf8))
        #expect(reparser.parseValue() == value)
    }

    @Test func `every name byte survives serialization`() throws {
        let source = "/" + (0 ... 255).map { String(format: "#%02X", $0) }.joined()
        var parser = PDFSourceParser(Array(source.utf8))
        let parsed = parser.parseValue()
        let value = try #require(parsed)
        var reparser = PDFSourceParser(Array(value.serialized.utf8))
        #expect(reparser.parseValue() == value)
    }

    @Test(arguments: [PDFFixtures.Shape.classic, .objectStreams])
    func `direct and indirect annotation arrays remain resolvable`(shape: PDFFixtures.Shape) throws {
        let file = PDFFixtures.make([.init(annots: .direct), .init(annots: .indirect)], shape: shape)
        let document = try PDFSourceDocument(file)
        for page in try document.pages() {
            guard case let .array(array) = try document.resolve(#require(page.dictionary["Annots"])) else {
                Issue.record("annotation array missing"); return
            }
            #expect(array.count == 1)
            guard case let .dictionary(dictionary) = try document.resolve(array[0]) else {
                Issue.record("annotation missing"); return
            }
            #expect(dictionary["Subtype"] == .name("Link"))
        }
        #expect(try document.object(999) == .null)
    }

    @Test func `cyclic page trees are unreadable`() throws {
        let file = PDFFixtures.updated(
            PDFFixtures.make([.init()]),
            redefining: 2,
            as: "<< /Type /Pages /Kids [2 0 R] /Count 1 >>",
        )
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(file).pages() }
    }

    @Test func `cyclic indirect values are unreadable`() throws {
        let file = PDFFixtures.updated(PDFFixtures.make([.init()]), redefining: 4, as: "4 0 R")
        let document = try PDFSourceDocument(file)
        #expect(throws: PDFAppendError.unreadable) { try document.resolve(.reference(4, 0)) }
    }

    @Test func `deep syntax is refused without recursion overflow`() {
        let source = String(repeating: "[", count: 1000) + "0" + String(repeating: "]", count: 1000)
        var parser = PDFSourceParser(Array(source.utf8))
        #expect(parser.parseValue() == nil)
    }

    @Test func `out of range startxref is unreadable`() {
        let file = Data("%PDF-1.4\nstartxref\n9223372036854775807\n%%EOF\n".utf8)
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(file) }
    }

    @Test func `flate decode handles empty and corrupt input`() throws {
        #expect(try FlateStream.decode(FlateStream.encode(Data()), limit: 1 << 20) == Data())
        #expect(throws: (any Error).self) { try FlateStream.decode(Data([0]), limit: 1 << 20) }
        #expect(throws: (any Error).self) { try FlateStream.decode(Data([0x78, 0x9C, 0xFF]), limit: 1 << 20) }
    }
}
