import CoreGraphics
import Foundation
import PDFKit
@testable import SheetMusicPDF
import Testing

@Suite @MainActor struct PDFImporterContentStreamTests {
    @Test func extractsAsciiTextOrigin() throws {
        let data = PDFFixtureBuilder.build(
            glyphs: [.init(
                unicodeScalar: "A",
                fontName: "Helvetica",
                fontSize: 12,
                origin: CGPoint(x: 100, y: 700)
            )]
        )
        let doc = try #require(PDFDocument(data: data))
        let walker = PDFImporter.ContentStreamWalker(document: doc)
        let out = try walker.walk()
        // Either captured as RawGlyph (SMuFL-style) or TextGlyph (Unicode).
        // Helvetica + ASCII should land in `texts`.
        #expect(out.texts.contains { $0.text.contains("A") })
        // Walker must record page index 0.
        #expect(out.texts.allSatisfy { $0.pageIndex == 0 })
    }

    @Test func extractsHorizontalPathSegment() throws {
        let data = PDFFixtureBuilder.build(
            paths: [.init(
                origin: CGPoint(x: 50, y: 500),
                kind: .horizontal(width: 400)
            )]
        )
        let doc = try #require(PDFDocument(data: data))
        let walker = PDFImporter.ContentStreamWalker(document: doc)
        let out = try walker.walk()
        let horiz = out.paths.filter { $0.kind == .horizontal }
        #expect(horiz.count >= 1)
        let rect = try #require(horiz.first?.rect)
        #expect(abs(rect.minX - 50) < 1.5)
        #expect(abs(rect.width - 400) < 1.5)
    }

    @Test func extractsVerticalPathSegment() throws {
        let data = PDFFixtureBuilder.build(
            paths: [.init(
                origin: CGPoint(x: 200, y: 400),
                kind: .vertical(height: 80)
            )]
        )
        let doc = try #require(PDFDocument(data: data))
        let walker = PDFImporter.ContentStreamWalker(document: doc)
        let out = try walker.walk()
        let vert = out.paths.filter { $0.kind == .vertical }
        #expect(vert.count >= 1)
    }

    @Test func multiplePagesEnumerated() throws {
        // Build a 2-page document by concatenating two PDFs via PDFDocument
        let p0 = PDFFixtureBuilder.build(
            paths: [.init(origin: CGPoint(x: 0, y: 100), kind: .horizontal(width: 100))]
        )
        let p1 = PDFFixtureBuilder.build(
            paths: [.init(origin: CGPoint(x: 0, y: 200), kind: .horizontal(width: 100))]
        )
        let doc = try #require(PDFDocument(data: p0))
        let aux = try #require(PDFDocument(data: p1))
        if let page = aux.page(at: 0) { doc.insert(page, at: doc.pageCount) }
        let walker = PDFImporter.ContentStreamWalker(document: doc)
        let out = try walker.walk()
        let pages = Set(out.paths.map(\.pageIndex))
        #expect(pages == [0, 1])
    }
}
