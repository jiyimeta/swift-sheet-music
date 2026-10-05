import Foundation
@testable import SheetMusicPDF
@testable import SheetMusicPDFWriter
import Testing

/// `PDFObjectWriter` and `FlateStream`: a file ssm's own Swift reader opens, whose cross-reference table points at
/// its objects, and whose compressed streams inflate back to what was written.
struct PDFObjectWriterTests {
    /// A one-page A4 document whose page draws `content`.
    private static func document(content: Data, compress: Bool) throws -> Data {
        let writer = PDFObjectWriter()
        let catalog = writer.reserve()
        let pages = writer.reserve()
        let page = writer.reserve()
        let contents = writer.reserve()
        let info = writer.reserve()
        writer.object(catalog, "<< /Type /Catalog /Pages \(pages) 0 R >>")
        writer.object(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        writer.object(
            page,
            "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 595.276 841.89] /Contents \(contents) 0 R >>",
        )
        try writer.stream(contents, dictionary: "", data: content, compress: compress)
        writer.object(info, "<< /Producer \(PDFString.text("folino (ssm)")) >>")
        return writer.finish(root: catalog, info: info)
    }

    @Test func `the reader opens the file and finds its page`() throws {
        let content = Data("0 0 0 rg 72 692 144 100 re f\n".utf8)

        let reader = try #require(PDFReaderDocument(data: Self.document(content: content, compress: false)))

        #expect(reader.pageCount == 1)
        let size = try #require(reader.mediaBox(page: 0))
        #expect(abs(size.width - 595.276) < 0.01)
        // The reader ends each content stream with a line feed of its own, so streams cannot run together.
        #expect(reader.contentBytes(page: 0) == content + Data("\n".utf8))
    }

    @Test func `a compressed stream inflates to what was written`() throws {
        // Long and repetitive, so it compresses: a staff's worth of lines.
        let content = Data((0 ..< 200).map { "72 \(700 - $0) m 523 \(700 - $0) l S\n" }.joined().utf8)
        let file = try Self.document(content: content, compress: true)

        let reader = try #require(PDFReaderDocument(data: file))

        #expect(file.count < content.count)
        #expect(reader.contentBytes(page: 0) == content + Data("\n".utf8))
    }

    @Test func `every cross-reference entry points at its object`() throws {
        let file = try [UInt8](Self.document(content: Data("q Q\n".utf8), compress: true))
        /// Byte for byte as Latin-1, so a string's offsets are the file's.
        func text(_ bytes: ArraySlice<UInt8>) throws -> String {
            try #require(String(bytes: bytes, encoding: .isoLatin1))
        }
        let whole = try text(file[...])
        let startXref = try #require(whole.range(of: "startxref\n", options: .backwards))
        let tableOffset = try #require(Int(whole[startXref.upperBound...].prefix { $0.isNumber }))
        let lines = try text(file[tableOffset...]).split(separator: "\n")

        #expect(lines[0] == "xref")
        #expect(lines[1] == "0 6")
        for number in 1 ... 5 {
            let offset = try #require(Int(lines[2 + number].prefix(10)))
            let atOffset = try text(file[offset ..< min(file.count, offset + 12)])
            #expect(atOffset.hasPrefix("\(number) 0 obj"), "object \(number) at \(offset): \(atOffset)")
        }
    }

    @Test func `an empty stream is still a zlib stream`() throws {
        let encoded = try FlateStream.encode(Data())

        #expect(PDFFlate.inflate(encoded) == Data())
    }

    @Test func `a text string is a literal when it can be, and UTF-16 when it cannot`() {
        #expect(PDFString.text("Prelude (No. 1) \\ C") == "(Prelude \\(No. 1\\) \\\\ C)")
        #expect(PDFString.text("前奏曲") == "<FEFF524D594F66F2>")
    }
}
