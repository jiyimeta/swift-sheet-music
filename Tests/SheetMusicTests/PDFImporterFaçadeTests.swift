import CoreGraphics
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicPDF
import Testing

struct PDFImporterFaçadeTests {
    @Test func emptyDataThrows() {
        #expect(throws: SheetMusicError.self) {
            _ = try PDFImporter.parse(pdfData: Data())
        }
    }

    @Test func nonPDFDataThrows() {
        #expect(throws: SheetMusicError.self) {
            _ = try PDFImporter.parse(pdfData: Data([0x00, 0x01, 0x02, 0x03]))
        }
    }

    @Test func optionsHaveSensibleDefaults() {
        let options = PDFImportOptions()
        #expect(options.preserveBreaks == true)
        #expect(options.useMetadataAsFallback == true)
        #expect(options.diagnostics == nil)
    }

    /// Smoke test: a synthetic PDF with a 5-line staff band drawn as
    /// horizontal paths is enough to exercise the assembled pipeline
    /// end-to-end. We don't assert on the score's musical contents —
    /// just that a non-empty Score is produced without throwing.
    @MainActor
    @Test func parsesNonEmptyScoreFromSyntheticPDF() throws {
        let lineYs: [CGFloat] = [400, 410, 420, 430, 440]
        let paths = lineYs.map {
            PDFFixtureBuilder.PathPlacement(
                origin: CGPoint(x: 50, y: $0),
                kind: .horizontal(width: 400),
            )
        }
        let data = PDFFixtureBuilder.build(paths: paths)
        let score = try PDFImporter.parse(pdfData: data)
        #expect(score.totalStaffCount > 0, "expected at least one staff detected")
        #expect(!score.parts.isEmpty)
    }
}
