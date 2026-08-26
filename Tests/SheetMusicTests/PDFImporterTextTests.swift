#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterTextTests {
        private let pageSize = CGSize(width: 595, height: 842)

        private func text(
            _ s: String, x: CGFloat, y: CGFloat, size: CGFloat = 12,
        ) -> TextGlyph {
            TextGlyph(
                text: s, fontName: "Helvetica", fontSize: size,
                origin: CGPoint(x: x, y: y),
                bbox: CGRect(x: x, y: y, width: 100, height: size),
                pageIndex: 0,
            )
        }

        private func defaultOptions(
            useMetadataAsFallback: Bool = true,
        ) -> PDFImportOptions {
            var opts = PDFImportOptions()
            opts.useMetadataAsFallback = useMetadataAsFallback
            return opts
        }

        @Test func extractsTitleFromLargestText() {
            let texts = [
                text("Title", x: 200, y: 800, size: 24),
                text("Subtitle", x: 200, y: 770, size: 14),
            ]
            let frame = PDFImporter.extractTitleFrame(
                texts: texts, pageSize: pageSize,
                documentAttributes: nil, options: defaultOptions(),
            )
            #expect(frame != nil)
            let titles = frame?.texts.filter { $0.style == .title } ?? []
            #expect(titles.count == 1)
            #expect(titles.first?.text == "Title")
        }

        @Test func extractsRightAlignedComposer() {
            let texts = [
                text("My Title", x: 200, y: 800, size: 24),
                text("Composer Name", x: 450, y: 770, size: 12),
            ]
            let frame = PDFImporter.extractTitleFrame(
                texts: texts, pageSize: pageSize,
                documentAttributes: nil, options: defaultOptions(),
            )
            let composers = frame?.texts.filter { $0.style == .composer } ?? []
            #expect(composers.count == 1)
            #expect(composers.first?.text == "Composer Name")
        }

        @Test func metadataFallbackTitleWhenNoText() {
            let frame = PDFImporter.extractTitleFrame(
                texts: [], pageSize: pageSize,
                documentAttributes: ["Title": "From Metadata"],
                options: defaultOptions(),
            )
            #expect(frame != nil)
            let titles = frame?.texts.filter { $0.style == .title } ?? []
            #expect(titles.first?.text == "From Metadata")
        }

        @Test func metadataFallbackDisabledReturnsNil() {
            let frame = PDFImporter.extractTitleFrame(
                texts: [], pageSize: pageSize,
                documentAttributes: ["Title": "From Metadata"],
                options: defaultOptions(useMetadataAsFallback: false),
            )
            #expect(frame == nil)
        }

        @Test func textBelowTopBandIsIgnored() {
            let texts = [
                text("Body Text", x: 200, y: 300, size: 12),
            ]
            let frame = PDFImporter.extractTitleFrame(
                texts: texts, pageSize: pageSize,
                documentAttributes: nil, options: defaultOptions(),
            )
            #expect(frame == nil)
        }
    }
#endif
