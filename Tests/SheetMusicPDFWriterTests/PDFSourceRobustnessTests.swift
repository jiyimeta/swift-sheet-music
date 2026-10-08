import Foundation
import SheetMusicPDFSyntax
@testable import SheetMusicPDFWriter
import Testing

struct PDFSourceRobustnessTests {
    @Test(arguments: [0, 1, 2, 3, 4])
    func `each PNG filter restores its original bytes`(filter: Int) throws {
        // Two 3-byte rows, with residuals calculated independently by hand.
        let residuals: [[UInt8]] = [
            [0, 10, 20, 30, 0, 15, 25, 35], [1, 10, 10, 10, 1, 15, 10, 10],
            [2, 10, 20, 30, 2, 5, 5, 5], [3, 10, 15, 20, 3, 10, 8, 8],
            [4, 10, 10, 10, 4, 5, 5, 5],
        ]
        let dictionary: [String: PDFObject] = ["DecodeParms": .dictionary([
            "Predictor": .int(15), "Columns": .int(3),
        ])]
        #expect(try PDFSourceDocument.decode(residuals[filter], dictionary: dictionary) == [10, 20, 30, 15, 25, 35])
    }

    @Test func `unsupported filters and predictors are refused`() {
        #expect(throws: PDFAppendError.unreadable) {
            try PDFSourceDocument.decode([0], dictionary: ["Filter": .name("LZWDecode")])
        }
        #expect(throws: PDFAppendError.unreadable) {
            try PDFSourceDocument.decode([0], dictionary: ["DecodeParms": .dictionary(["Predictor": .int(2)])])
        }
        #expect(throws: PDFAppendError.unreadable) {
            try PDFSourceDocument.decode([9, 0], dictionary: ["DecodeParms": .dictionary(["Predictor": .int(12)])])
        }
    }

    /// A few kilobytes of `/FlateDecode` can ask for gigabytes; a stream decodes up to the budget and no further.
    @Test func `a stream that decodes past the budget is refused`() throws {
        let budget = PDFSourceDocument.maxDecodedStreamBytes
        let flate: [String: PDFObject] = ["Filter": .name("FlateDecode")]
        let atBudget = try Array(PDFFlate.encode(Data(count: budget)))
        let overBudget = try Array(PDFFlate.encode(Data(count: budget + 1)))
        #expect(overBudget.count < 64 * 1024)
        #expect(try PDFSourceDocument.decode(atBudget, dictionary: flate).count == budget)
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument.decode(overBudget, dictionary: flate) }
    }

    @Test func `indirect and wrong stream lengths remain readable`() throws {
        for length in ["5 0 R", "999999999", "-1"] {
            var file = PDFFixtures.updated(
                PDFFixtures.make([.init()]),
                redefining: 4,
                as: "<< /Length \(length) >>\nstream\nabc\nendstream",
            )
            if length == "5 0 R" { file = PDFFixtures.updated(file, redefining: 5, as: "3") }
            #expect(try PDFSourceDocument(file).object(4) == .stream(dictionary: ["Length": length == "5 0 R"
                    ? .reference(5, 0) : .int(#require(Int(length)))], raw: [97, 98, 99]))
        }
    }

    @Test func `hybrid streams supply compressed locations over table placeholders`() throws {
        let document = try PDFSourceDocument(hybrid())
        #expect(!document.lastSectionIsStream)
        #expect(try document.pages().first?.space.displayedSize == PDFPageSize(width: 300, height: 400))
    }

    @Test func `newer free entries cannot be resurrected by an older hybrid stream`() throws {
        let old = try hybrid()
        let start = old.count
        let previous = try PDFSourceDocument(old).startXRef
        let update = "xref\n3 1\n0000000000 00000 f \ntrailer\n"
            + "<< /Size 6 /Root 1 0 R /Prev \(previous) >>\nstartxref\n\(start)\n%%EOF\n"
        #expect(try PDFSourceDocument(old + Data(update.utf8)).object(3) == .null)
    }

    @Test func `cyclic previous sections are unreadable`() {
        let old = PDFFixtures.make([.init()])
        let start = old.count
        let update = "xref\n0 1\n0000000000 65535 f \ntrailer\n"
            + "<< /Size 5 /Root 1 0 R /Prev \(start) >>\nstartxref\n\(start)\n%%EOF\n"
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(old + Data(update.utf8)) }
    }

    @Test func `malformed xref ranges and wide overflowing fields are unreadable`() throws {
        let dictionaries = [
            "/Type /XRef /Size 5 /Root 1 0 R /W [1 2 2] /Index [0 -1]",
            "/Type /XRef /Size 5 /Root 1 0 R /W [1 8 1] /Index [3 1]",
            "/Type /XRef /Size 1 /Root 1 0 R /W [1 /Bad 2 2]",
            "/Type /XRef /Size 5 /Root 1 0 R /W [1 2 2] /Index [0 /Bad 1]",
        ]
        for dictionary in dictionaries {
            var file = Data("%PDF-1.5\n".utf8)
            let start = file.count
            file += Data("5 0 obj\n".utf8)
            try file += Data(PDFObjectWriter.streamBody(
                dictionary: dictionary,
                data: Data(repeating: 255, count: 10),
                compress: false,
            ))
            file += Data("endobj\nstartxref\n\(start)\n%%EOF\n".utf8)
            #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(file) }
        }
    }

    @Test func `huge empty predictor rows are refused before allocation`() {
        #expect(throws: PDFAppendError.unreadable) {
            try PDFSourceDocument.decode([], dictionary: ["DecodeParms": .dictionary([
                "Predictor": .int(12), "Columns": .int(1_000_000),
            ])])
        }
    }

    @Test func `overflowing page dimensions are unreadable`() {
        let file = PDFFixtures.make([.init(mediaBox: "[-1e308 -1e308 1e308 1e308]")])
        #expect(throws: PDFAppendError.unreadable) { try PDFSourceDocument(file).pages() }
    }

    private func hybrid() throws -> Data {
        var file = PDFFixtures.make([.init()])
        let previous = try PDFSourceDocument(file).startXRef
        let pageOffset = file.count
        file += Data("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>\nendobj\n".utf8)
        let streamOffset = file.count
        file += Data("5 0 obj\n".utf8)
        try file += Data(PDFObjectWriter.streamBody(
            dictionary: "/Type /XRef /Size 6 /W [1 2 2] /Index [3 1]",
            data: Data([1, UInt8(truncatingIfNeeded: pageOffset >> 8), UInt8(truncatingIfNeeded: pageOffset), 0, 0]),
            compress: false,
        ))
        file += Data("endobj\n".utf8)
        let start = file.count
        file += Data(("xref\n3 1\n0000000000 00000 f \ntrailer\n"
                + "<< /Size 6 /Root 1 0 R /XRefStm \(streamOffset) /Prev \(previous) >>\n"
                + "startxref\n\(start)\n%%EOF\n").utf8)
        return file
    }
}
