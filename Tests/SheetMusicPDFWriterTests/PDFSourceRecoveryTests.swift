import Foundation
@testable import SheetMusicPDFWriter
import Testing

struct PDFSourceRecoveryTests {
    @Test func `a malformed latest xref cannot fall back to a valid old section`() throws {
        let old = PDFFixtures.make([.init()])
        let previous = try PDFSourceDocument(old).startXRef
        let offset = old.count
        let update = "xref\n3 1\n0000000010 00000 bad \ntrailer\n"
            + "<< /Size 5 /Root 1 0 R /Prev \(previous) >>\nstartxref\n\(offset)\n%%EOF\n"
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(old + Data(update.utf8)) }
    }

    @Test(arguments: ["stream", "string", "comment"])
    func `object recovery ignores fake page headers in payload`(kind: String) throws {
        let fake = "3 0 obj << /Type /Page /MediaBox [0 0 1 1] >> endobj"
        let body: String
        switch kind {
        case "stream": body = "<< /Length \(fake.utf8.count) >>\nstream\n\(fake)\nendstream"
        case "string": body = "(\n\(fake)\n)"
        default: body = "null\n% \(fake)"
        }
        let old = PDFFixtures.make([.init()])
        let file = PDFFixtures.updated(old, redefining: 4, as: body)
        let pageOffset = try #require(String(bytes: old, encoding: .utf8)?.range(of: "3 0 obj"))
        let text = try #require(String(bytes: old, encoding: .utf8))
        let offset = text.utf8.distance(from: text.utf8.startIndex, to: pageOffset.lowerBound) + 1
        let document = try PDFSourceDocument(repoint(file, object: 3, to: offset))
        #expect(try document.pages().first?.space.displayedSize == PDFPageSize(width: 612, height: 792))
    }

    @Test func `ambiguous visible object headers are not recovered`() throws {
        let old = PDFFixtures.make([.init()])
        let text = try #require(String(bytes: old, encoding: .utf8))
        let header = try #require(text.range(of: "3 0 obj"))
        let offset = text.utf8.distance(from: text.utf8.startIndex, to: header.lowerBound) + 1
        let file = PDFFixtures.updated(old, redefining: 3, as: "<< /Type /Page /MediaBox [0 0 300 400] >>")
        #expect(throws: PDFAppendError.unreadable) {
            try PDFSourceDocument(repoint(file, object: 3, to: offset)).pages()
        }
    }

    @Test func `xref recovery excludes section syntax inside a stream`() throws {
        let fake = "xref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 5 /Root 1 0 R >>"
        let old = PDFFixtures.make([.init()])
        let body = "<< /Length \(fake.utf8.count) >>\nstream\n\(fake)\nendstream"
        let file = PDFFixtures.updated(old, redefining: 4, as: body)
        let text = try #require(String(bytes: file, encoding: .utf8))
        let payload = try #require(text.range(of: "stream\nxref"))
        let offset = text.utf8.distance(from: text.utf8.startIndex, to: payload.lowerBound) + 8
        let tail = "startxref\n\(offset)\n%%EOF\n"
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(file + Data(tail.utf8)) }
    }

    @Test func `page boxes resolve indirect scalar coordinates`() throws {
        var file = PDFFixtures.updated(
            PDFFixtures.make([.init()]),
            redefining: 3,
            as: "<< /Type /Page /Parent 2 0 R /MediaBox [5 0 R 6 0 R 7 0 R 8 0 R] >>",
        )
        for (number, value) in [(5, "10"), (6, "20"), (7, "310.25"), (8, "420.5")] {
            file = PDFFixtures.updated(file, redefining: number, as: value)
        }
        let space = try #require(try PDFSourceDocument(file).pages().first).space
        #expect(space == PDFPageSpace(left: 10, bottom: 20, right: 310.25, top: 420.5, rotation: 0))
    }

    @Test(arguments: ["[0 /Bad 0 300 400]", "[0 /Bad 300 400]", "/Bad", "[0 0 300]"])
    func `present malformed media boxes are unreadable`(box: String) {
        let file = PDFFixtures.make([.init(mediaBox: box)])
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(file).pages() }
    }

    @Test func `present malformed crop boxes are unreadable`() {
        let file = PDFFixtures.make([.init(extra: " /CropBox [0 0 /Bad 400]")])
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(file).pages() }
    }

    @Test func `recovery refuses an unproven indirect stream boundary`() throws {
        let old = PDFFixtures.make([.init()])
        let text = try #require(String(bytes: old, encoding: .utf8))
        let header = try #require(text.range(of: "3 0 obj"))
        let offset = text.utf8.distance(from: text.utf8.startIndex, to: header.lowerBound) + 1
        var file = PDFFixtures.updated(
            old,
            redefining: 4,
            as: "<< /Length 5 0 R >>\nstream\nabc\nendstream",
        )
        file = PDFFixtures.updated(file, redefining: 5, as: "3")
        #expect(try PDFSourceDocument(file).pages().count == 1)
        #expect(throws: PDFAppendError.unreadable) {
            try PDFSourceDocument(repoint(file, object: 3, to: offset)).pages()
        }
    }

    @Test func `ambiguous top level section boundaries are not recovered`() throws {
        let old = PDFFixtures.make([.init()])
        let file = PDFFixtures.updated(old, redefining: 3, as: "<< /Type /Page /MediaBox [0 0 300 400] >>")
        let offset = try PDFSourceDocument(file).startXRef + 1
        let tail = "startxref\n\(offset)\n%%EOF\n"
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(file + Data(tail.utf8)) }
    }

    private func repoint(_ file: Data, object: Int, to offset: Int) throws -> Data {
        let document = try PDFSourceDocument(file)
        let start = file.count
        let entry = String(offset)
        let digits = String(repeating: "0", count: max(0, 10 - entry.count)) + entry
        let update = "xref\n\(object) 1\n\(digits) 00000 n \ntrailer\n"
            + "<< /Size \(document.size) /Root 1 0 R /Prev \(document.startXRef) >>\n"
            + "startxref\n\(start)\n%%EOF\n"
        return file + Data(update.utf8)
    }
}
