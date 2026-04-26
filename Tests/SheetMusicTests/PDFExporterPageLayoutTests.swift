import CoreGraphics
import Foundation
import PDFKit
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicPDF
import Testing

@Suite @MainActor struct PDFExporterPageLayoutTests {
    /// Default options should yield a MediaBox matching
    /// `pageLayout.{width,height} × 72`. testArpeggio.mscx declares
    /// A4-sized paper.
    @Test func mediaBoxMatchesScorePageSize() async throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let url = try #require(Bundle.module.url(
            forResource: "testArpeggio", withExtension: "mscx"))
        let score = try MSCXParser.parse(
            try Data(contentsOf: url))
        let data = try PDFExporter.export(score: score)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        let expectedWidth = score.style.pageLayout.width * 72
        let expectedHeight = score.style.pageLayout.height * 72
        #expect(abs(bounds.width - expectedWidth) < 0.01)
        #expect(abs(bounds.height - expectedHeight) < 0.01)
    }

    /// `staffSize` denotes total staff height (= 4 × sp), so it
    /// resolves to `4 × spatium_mm × 72 / 25.4`. With a 1.76389mm
    /// spatium that's ~20.0 pt.
    @Test func staffSizeFollowsSpatium() async throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let url = try #require(Bundle.module.url(
            forResource: "testArpeggio", withExtension: "mscx"))
        let score = try MSCXParser.parse(
            try Data(contentsOf: url))
        let resolved = PDFExporter.resolve(
            options: PDFExporter.Options(), score: score)
        let expected = CGFloat(4 * score.style.spatium * 72.0 / 25.4)
        #expect(abs(resolved.staffSize - expected) < 1e-6)
    }

    /// Explicit override beats `.fromScore` resolution.
    @Test func explicitStaffSizeWins() async throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Score(division: 480)
        let resolved = PDFExporter.resolve(
            options: PDFExporter.Options(
                staffSize: .explicit(14)),
            score: score)
        #expect(resolved.staffSize == 14)
    }

    /// Page 1 (index 0) uses oddMargins; page 2 uses evenMargins
    /// when twosided, oddMargins otherwise.
    @Test func twosidedAlternatesMargins() {
        var layout = PageLayout.museScoreA4
        layout.oddLeftMargin = 0.5
        layout.evenLeftMargin = 1.0
        layout.twosided = true
        let page = EngravingPage.from(layout)
        #expect(page.margins(forPageIndex: 0).leading
                == 0.5 * 72)
        #expect(page.margins(forPageIndex: 1).leading
                == 1.0 * 72)
        #expect(page.margins(forPageIndex: 2).leading
                == 0.5 * 72)
    }

    @Test func singleSidedKeepsOddMargins() {
        var layout = PageLayout.museScoreA4
        layout.oddLeftMargin = 0.5
        layout.evenLeftMargin = 1.0
        layout.twosided = false
        let page = EngravingPage.from(layout)
        #expect(page.margins(forPageIndex: 0).leading
                == 0.5 * 72)
        #expect(page.margins(forPageIndex: 1).leading
                == 0.5 * 72)
    }

    /// Right margin derives per `Page::rm`:
    /// `width - printableWidth - leftMargin`.
    @Test func rightMarginDerivedFromPrintableWidth() {
        var layout = PageLayout.museScoreA4
        layout.width = 10
        layout.printableWidth = 8
        layout.oddLeftMargin = 1
        layout.evenLeftMargin = 1.5
        #expect(layout.oddRightMargin == 1)
        #expect(layout.evenRightMargin == 0.5)
    }
}
