import CoreGraphics
import Foundation
import PDFKit
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicPDF
@testable import SheetMusicUI
import Testing

@MainActor struct PDFExporterPageLayoutTests {
    /// Default options should yield a MediaBox matching
    /// `pageLayout.{width,height} × 72`. testArpeggio.mscx declares
    /// A4-sized paper.
    @Test func mediaBoxMatchesScorePageSize() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let url = try #require(Bundle.module.url(
            forResource: "testArpeggio", withExtension: "mscx",
        ))
        let score = try MSCXParser.parse(
            Data(contentsOf: url),
        )
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
    @Test func staffSizeFollowsSpatium() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let url = try #require(Bundle.module.url(
            forResource: "testArpeggio", withExtension: "mscx",
        ))
        let score = try MSCXParser.parse(
            Data(contentsOf: url),
        )
        let resolved = PDFExporter.resolve(
            options: PDFExporter.Options(), score: score,
        )
        let expected = CGFloat(4 * score.style.spatium * 72.0 / 25.4)
        #expect(abs(resolved.staffSize - expected) < 1e-6)
    }

    /// Explicit override beats `.fromScore` resolution.
    @Test func explicitStaffSizeWins() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Score(division: 480)
        let resolved = PDFExporter.resolve(
            options: PDFExporter.Options(
                staffSize: .explicit(14),
            ),
            score: score,
        )
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
        #expect(
            page.margins(forPageIndex: 0).leading
                == 0.5 * 72,
        )
        #expect(
            page.margins(forPageIndex: 1).leading
                == 1.0 * 72,
        )
        #expect(
            page.margins(forPageIndex: 2).leading
                == 0.5 * 72,
        )
    }

    @Test func singleSidedKeepsOddMargins() {
        var layout = PageLayout.museScoreA4
        layout.oddLeftMargin = 0.5
        layout.evenLeftMargin = 1.0
        layout.twosided = false
        let page = EngravingPage.from(layout)
        #expect(
            page.margins(forPageIndex: 0).leading
                == 0.5 * 72,
        )
        #expect(
            page.margins(forPageIndex: 1).leading
                == 0.5 * 72,
        )
    }

    /// `<LayoutBreak>page` on a measure forces the next system to
    /// start a new PDF page even when the current page would still
    /// have vertical room for it.
    @Test func paginatePageBreakClosesPage() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let pageGeom = EngravingPage(
            size: CGSize(width: 600, height: 1200),
            oddMargins: PageMargins(uniform: 30),
            evenMargins: PageMargins(uniform: 30),
            twosided: false,
        )
        /// Three short systems that together fit on one page.
        /// System 1's last measure carries pageBreak → forces close.
        func sys(
            originY: CGFloat,
            lastMeasurePageBreak: Bool,
        ) -> LayoutSystem {
            let m = LayoutMeasure(
                measureIndex: 0, origin: .zero, width: 100,
                elements: [], pageBreak: lastMeasurePageBreak,
            )
            return LayoutSystem(
                origin: CGPoint(x: 0, y: originY),
                size: CGSize(width: 100, height: 200),
                measures: [m],
                staffOrigins: [.zero],
                partLabels: [],
                spanners: [],
                sp: 7.0,
            )
        }
        let s0 = sys(originY: 0, lastMeasurePageBreak: true)
        let s1 = sys(originY: 220, lastMeasurePageBreak: false)
        let s2 = sys(originY: 440, lastMeasurePageBreak: false)
        let pages = PDFExporter.paginate(
            systems: [s0, s1, s2], page: pageGeom,
        )
        // s0 closes its page (page 1) by the explicit pageBreak;
        // s1 + s2 share page 2.
        #expect(pages.count == 2)
        #expect(pages[0].systems.count == 1)
        #expect(pages[1].systems.count == 2)
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
