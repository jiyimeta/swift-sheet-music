import Foundation
@testable import SheetMusicPDFWriter
import Testing
#if canImport(PDFKit)
    import PDFKit
#endif

/// Incremental updates preserve the source file and add annotations only to the requested pages.
struct PDFIncrementalAnnotatorTests {
    static let ink = PDFPageAnnotationTests.ink(x: 20, y: 30)

    @Test(arguments: [PDFFixtures.Shape.classic, .objectStreams])
    func `the source remains a prefix and annotations appear only on the requested page`(
        shape: PDFFixtures.Shape,
    ) throws {
        let original = PDFFixtures.make([.init(), .init()], shape: shape)
        let appended = try PDFIncrementalAnnotator.append([1: [Self.ink]], to: original)
        #expect(appended.prefix(original.count) == original)
        let document = try PDFSourceDocument(appended)
        #expect(document.lastSectionIsStream == (shape == .objectStreams))
        #expect(try document.trailer["Prev"] == .int(PDFSourceDocument(original).startXRef))
        let pages = try document.pages()
        #expect(pages[0].dictionary["Annots"] == nil)
        #expect(try Self.subtypes(pages[1], in: document) == [.name("Ink")])
    }

    @Test(arguments: [PDFFixtures.Annots.direct, .indirect])
    func `existing annotations precede new annotations`(existing: PDFFixtures.Annots) throws {
        let original = PDFFixtures.make([.init(annots: existing)])
        let document = try PDFSourceDocument(PDFIncrementalAnnotator.append([0: [Self.ink]], to: original))
        #expect(try Self.subtypes(#require(document.pages().first), in: document) == [.name("Link"), .name("Ink")])
    }

    @Test func `shared indirect arrays do not spread additions to another page`() throws {
        let original = PDFFixtures.make([.init(annots: .indirect), .init(extra: " /Annots 5 0 R")])
        let document = try PDFSourceDocument(PDFIncrementalAnnotator.append([0: [Self.ink]], to: original))
        let pages = try document.pages()
        #expect(try Self.subtypes(pages[0], in: document) == [.name("Link"), .name("Ink")])
        #expect(try Self.subtypes(pages[1], in: document) == [.name("Link")])
    }

    @Test func `rotated offset crop boxes map displayed geometry into user space`() throws {
        let original = PDFFixtures.make([.init(extra: " /Rotate 90 /CropBox [10 20 210 120]")])
        #expect(try PDFIncrementalAnnotator.pageSizes(of: original) == [PDFPageSize(width: 100, height: 200)])
        let appended = try PDFIncrementalAnnotator.append([0: [Self.ink]], to: original)
        #expect((String(bytes: appended, encoding: .isoLatin1) ?? "").contains("/InkList [[40 40 40 50]]"))
    }

    @Test func `nothing visible to add leaves the source untouched`() throws {
        let original = PDFFixtures.make([.init()])
        let empty = PDFPageAnnotationTests.ink(clip: PDFClipPath(elements: [], evenOdd: false))
        let zero = PDFPageAnnotation.highlight(PDFHighlightAnnotation(
            rect: PDFPageRect(x: 0, y: 0, width: 0, height: 10), color: PDFPageAnnotationTests.red,
        ))
        #expect(try PDFIncrementalAnnotator.append([:], to: original) == original)
        #expect(try PDFIncrementalAnnotator.append([0: []], to: original) == original)
        #expect(try PDFIncrementalAnnotator.append([0: [empty, zero]], to: original) == original)
    }

    @Test(arguments: [-1, 3])
    func `out of range pages are refused`(index: Int) {
        #expect(throws: PDFAppendError.pageOutOfRange) {
            try PDFIncrementalAnnotator.append([index: [Self.ink]], to: PDFFixtures.make([.init()]))
        }
    }

    @Test func `encrypted and malformed sources are refused`() {
        let encrypted = PDFFixtures.make([.init()], trailerExtra: " /Encrypt << /Filter /Standard /V 1 >>")
        #expect(throws: PDFAppendError.encrypted) {
            try PDFIncrementalAnnotator.append([0: [Self.ink]], to: encrypted)
        }
        #expect(throws: PDFAppendError.unreadable) {
            try PDFIncrementalAnnotator.append([0: [Self.ink]], to: Data("not a PDF".utf8))
        }
        #expect(throws: PDFAppendError.unreadable) {
            try PDFIncrementalAnnotator.append([0: [Self.ink]], to: PDFFixtures.make([.init(extra: " /Annots 4 0 R")]))
        }
    }

    @Test func `trailer identity metadata and page dictionary precision survive`() throws {
        let original = PDFFixtures.make(
            [.init(extra: " /Custom 0.123456789012345 /Label (hello)")],
            trailerExtra: " /Info << /Title (Original) >> /ID [<0102> <0304>]",
        )
        let source = try PDFSourceDocument(original)
        let updated = try PDFSourceDocument(PDFIncrementalAnnotator.append([0: [Self.ink]], to: original))
        #expect(updated.trailer["Info"] == source.trailer["Info"])
        #expect(updated.trailer["ID"] == source.trailer["ID"])
        #expect(try updated.pages()[0].dictionary["Custom"] == source.pages()[0].dictionary["Custom"])
        #expect(try updated.pages()[0].dictionary["Label"] == .string(Array("hello".utf8)))
    }

    @Test(arguments: [PDFFixtures.Shape.classic, .objectStreams])
    func `repeated updates keep both annotation sets`(shape: PDFFixtures.Shape) throws {
        let original = PDFFixtures.make([.init()], shape: shape)
        let first = try PDFIncrementalAnnotator.append([0: [Self.ink]], to: original)
        let second = try PDFIncrementalAnnotator.append([0: [Self.ink]], to: first)
        #expect(second.prefix(first.count) == first)
        let document = try PDFSourceDocument(second)
        #expect(try Self.subtypes(#require(document.pages().first), in: document) == [.name("Ink"), .name("Ink")])
    }

    @Test func `an exhausted object namespace fails without overflowing`() {
        let original = PDFFixtures.make([.init()], trailerExtra: " /Size \(Int.max)")
        #expect(throws: PDFAppendError.unreadable) {
            try PDFIncrementalAnnotator.append([0: [Self.ink]], to: original)
        }
    }

    @Test func `null annotation entries are absent and exhausted namespaces allow empty additions`() throws {
        let original = PDFFixtures.make([.init(extra: " /Annots null")])
        let document = try PDFSourceDocument(PDFIncrementalAnnotator.append([0: [Self.ink]], to: original))
        #expect(try Self.subtypes(#require(document.pages().first), in: document) == [.name("Ink")])
        let exhausted = PDFFixtures.make([.init()], trailerExtra: " /Size \(Int.max)")
        let empty = PDFPageAnnotationTests.ink(clip: PDFClipPath(elements: [], evenOdd: false))
        #expect(try PDFIncrementalAnnotator.append([0: [empty]], to: exhausted) == exhausted)
    }

    @Test func `rewritten page objects retain their nonzero generation`() throws {
        let original = PDFFixtures.make([.init()])
        let source = try PDFSourceDocument(original)
        guard case let .offset(offset)? = source.locations[3] else { return }
        let entry = String(repeating: "0", count: 10 - String(offset).count) + String(offset)
        let text = (String(bytes: original, encoding: .isoLatin1) ?? "")
            .replacingOccurrences(of: "3 0 R", with: "3 7 R")
            .replacingOccurrences(of: "3 0 obj", with: "3 7 obj")
            .replacingOccurrences(of: entry + " 00000 n", with: entry + " 00007 n")
        let appended = try PDFIncrementalAnnotator.append([0: [Self.ink]], to: Data(text.utf8))
        let updated = try PDFSourceDocument(appended)
        #expect(try updated.pages()[0].generation == 7)
        let section = String(bytes: appended.dropFirst(original.count), encoding: .isoLatin1) ?? ""
        #expect(section.contains("3 7 obj\n"))
        #expect(try Self.subtypes(#require(updated.pages().first), in: updated) == [.name("Ink")])
    }

    @Test func `a file this writer made accepts an update`() throws {
        let original = try PDFPageAnnotationTests.write(pages: 2)
        let appended = try PDFIncrementalAnnotator.append([0: [Self.ink]], to: original)
        #expect(appended.prefix(original.count) == original)
        #expect(try PDFSourceDocument(appended).pages().count == 2)
    }

    #if canImport(PDFKit)
        @Test(arguments: [PDFFixtures.Shape.classic, .objectStreams])
        func `PDFKit sees the original link followed by the ink`(shape: PDFFixtures.Shape) throws {
            let original = PDFFixtures.make([.init(), .init(annots: .direct)], shape: shape)
            let appended = try PDFIncrementalAnnotator.append([1: [Self.ink]], to: original)
            let document = try #require(PDFDocument(data: appended))
            #expect(document.pageCount == 2)
            #expect(try #require(document.page(at: 0)).annotations.isEmpty)
            #expect(try #require(document.page(at: 1)).annotations.map(\.type) == ["Link", "Ink"])
        }
    #endif

    static func subtypes(_ page: PDFSourcePage, in document: PDFSourceDocument) throws -> [PDFSourceValue?] {
        let values = try #require(try document.resolve(page.dictionary["Annots"] ?? .null).array)
        return try values.map { try document.resolve($0).dictionary?["Subtype"] }
    }
}
