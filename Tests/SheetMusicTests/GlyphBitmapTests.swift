#if !os(Android)
    import CoreGraphics
    import CoreText
    import Foundation
    import PDFKit
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct GlyphBitmapTests {
        @Test func normalizesAPathToACenteredCoverageBitmap() {
            // A filled square occupying the left half of its own bbox must
            // normalize to a full-coverage bitmap (normalization scales the
            // bbox to fill the frame).
            let path = CGMutablePath()
            path.addRect(CGRect(x: 0, y: 0, width: 10, height: 10))
            let bmp = normalizedBitmap(path: path)
            #expect(bmp.coverage.count == GlyphBitmap.size * GlyphBitmap.size)
            // Interior is inked.
            let mid = GlyphBitmap.size / 2 * GlyphBitmap.size + GlyphBitmap.size / 2
            #expect(bmp.coverage[mid] > 200)
        }

        @Test func distinguishesTwoDifferentShapes() {
            let square = CGMutablePath()
            square.addRect(CGRect(x: 0, y: 0, width: 10, height: 10))
            let ring = CGMutablePath()
            ring.addEllipse(in: CGRect(x: 0, y: 0, width: 10, height: 10))
            ring.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 5, height: 5))
            #expect(normalizedBitmap(path: square) != normalizedBitmap(path: ring))
        }

        @Test func buildsCTFontFromAnchorEmbeddedProgram() throws {
            let p = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/pdf_test/ギブス.pdf")
            guard FileManager.default.fileExists(atPath: p.path) else { return }
            let doc = try #require(PDFDocument(url: p))
            let cgPage = try #require(doc.page(at: 0)?.pageRef)
            let fonts = PDFImporter.extractEmbeddedFonts(cgPage: cgPage)
            let candidates = fonts.values.compactMap { f -> CTFont? in
                guard let program = f.program, let kind = f.programKind
                else { return nil }
                return makeCTFont(program: program, kind: kind)
            }
            #expect(!candidates.isEmpty)
            // Every usable font must yield at least one non-empty outline.
            let font = try #require(candidates.first)
            let count = CTFontGetGlyphCount(font)
            #expect(count > 0)
            var found = false
            for g in 1 ..< min(count, 200) {
                if let path = CTFontCreatePathForGlyph(font, CGGlyph(g), nil),
                   !path.isEmpty
                {
                    found = true
                    break
                }
            }
            #expect(found)
        }
    }
#endif
