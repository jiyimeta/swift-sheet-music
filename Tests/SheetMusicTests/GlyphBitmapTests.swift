#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    import PDFKit
    @testable import SheetMusicPDF
    import Testing

    struct GlyphBitmapTests {
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
            // Target the SMuFL music font DETERMINISTICALLY — Dictionary
            // iteration order is unspecified, and this spike's entire point is
            // Leland specifically, not "some font or other". Subset-embedded
            // fonts are commonly renamed "ABCDEF+Leland"; match the suffix
            // after any "+" so that convention doesn't break the lookup.
            let leland = try #require(fonts.values.first { f in
                let base = f.baseFont.split(separator: "+").last.map(String.init)
                    ?? f.baseFont
                return base == "Leland"
            })
            let program = try #require(leland.program)
            _ = try #require(leland.programKind)
            let font = try #require(makeCTFont(program: program))

            let count = CTFontGetGlyphCount(font)
            #expect(count > 0)
            var nonEmptyOutlines = 0
            for g in 1 ..< count {
                if let path = CTFontCreatePathForGlyph(font, CGGlyph(g), nil),
                   !path.isEmpty
                {
                    nonEmptyOutlines += 1
                }
            }
            // Not merely "at least one" — the subset must be substantially
            // usable, or the outline-based classifier in Tasks 9-12 has
            // nothing to work with. (Observed on this anchor: 24 of 25
            // glyphs, i.e. every glyph but .notdef.)
            #expect(nonEmptyOutlines >= 10)
        }
    }
#endif
