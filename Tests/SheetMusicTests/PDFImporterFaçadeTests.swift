import Foundation
@testable import SheetMusicCore
@testable import SheetMusicPDF
import Testing

@Suite struct PDFImporterFaçadeTests {
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
}
