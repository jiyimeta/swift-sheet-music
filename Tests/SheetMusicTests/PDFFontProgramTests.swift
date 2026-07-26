#if !os(Android)
    import CoreGraphics
    import Foundation
    import PDFKit
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFFontProgramTests {
        /// The corpus anchor is a MuseScore 3.6.2 export embedding Leland.
        /// Skipped when the corpus is absent so CI (which has no corpus)
        /// still passes.
        private var anchorURL: URL? {
            let p = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/pdf_test/ギブス.pdf")
            return FileManager.default.fileExists(atPath: p.path) ? p : nil
        }

        @Test func extractsBaseFontAndProgramFromAnchor() throws {
            guard let url = anchorURL else { return }
            let doc = try #require(PDFDocument(url: url))
            let page = try #require(doc.page(at: 0))
            let cgPage = try #require(page.pageRef)
            let fonts = PDFImporter.extractEmbeddedFonts(cgPage: cgPage)
            #expect(!fonts.isEmpty)
            // At least one embedded music font with a retrievable program.
            let withProgram = fonts.values.filter { $0.program != nil }
            #expect(!withProgram.isEmpty)
            for f in withProgram {
                #expect(!f.baseFont.isEmpty)
                #expect((f.program?.count ?? 0) > 1000)
                #expect(f.programKind != nil)
            }
        }
    }
#endif
