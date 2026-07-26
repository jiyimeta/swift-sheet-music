#if !os(Android)
    import CoreGraphics
    import CoreText
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct GlyphClassifierTests {
        @Test func tier1SMuFLCodepointWinsWhenPresent() {
            let c = GlyphClassifier(font: nil)
            #expect(c.classify(codepoint: 0xE0A4, glyphID: nil) == .noteheadBlack)
            #expect(c.classify(codepoint: 0xE050, glyphID: nil) == .clefG)
        }

        @Test func tier2GlyphNameResolvesNonSMuFLCodepoint() {
            var font = PDFImporter.EmbeddedFont()
            font.baseFont = "ABCDEF+Maestro"
            font.differences = [0x6E: "quarterrest", 0x77: "sharp"]
            let c = GlyphClassifier(font: font)
            // 0x6E is not a SMuFL PUA codepoint, so Tier 1 cannot fire.
            #expect(c.classify(codepoint: 0x6E, glyphID: nil) == .rest(.quarter))
            #expect(c.classify(codepoint: 0x77, glyphID: nil) == .accidentalSharp)
        }

        @Test func unresolvableCodepointStaysUnknown() {
            let c = GlyphClassifier(font: nil)
            #expect(c.classify(codepoint: 0x41, glyphID: nil) == .unknown(0x41))
        }

        @Test func tier1IsUnaffectedByAnEmbeddedFont() {
            var font = PDFImporter.EmbeddedFont()
            font.differences = [0xE0A4: "quarterrest"] // deliberately wrong
            let c = GlyphClassifier(font: font)
            // Tier 1 must win — a SMuFL codepoint is authoritative.
            #expect(c.classify(codepoint: 0xE0A4, glyphID: nil) == .noteheadBlack)
        }

        @Test func canClassifyWithoutCMapWhenDifferencesPresent() {
            var font = PDFImporter.EmbeddedFont()
            font.differences = [0x6E: "quarterrest"]
            let c = GlyphClassifier(font: font)
            #expect(c.canClassifyWithoutCMap)
        }

        @Test func cannotClassifyWithoutCMapWhenNoFont() {
            let c = GlyphClassifier(font: nil)
            #expect(!c.canClassifyWithoutCMap)
        }

        @Test func cannotClassifyWithoutCMapWhenFontHasNeitherDifferencesNorProgram() {
            let font = PDFImporter.EmbeddedFont()
            let c = GlyphClassifier(font: font)
            #expect(!c.canClassifyWithoutCMap)
        }

        // MARK: Tier 4 gate (`enableShapeMatching`, default off)

        @Test func defaultOptionsLeaveShapeMatchingDisabled() {
            #expect(PDFImportOptions().enableShapeMatching == false)
        }

        /// Locates the bundled Bravura.otf resource (owned by
        /// `SheetMusicLayoutApple`, linked into this test binary because
        /// `SheetMusicTests` depends on it) without any dependency on the
        /// developer's local `~/Desktop` corpus, so these tests are not
        /// environment-dependent. Returns nil (callers skip gracefully) if
        /// the resource can't be found in this process's loaded bundles.
        private static func loadBravuraOTFData() -> Data? {
            for bundle in Bundle.allBundles + Bundle.allFrameworks {
                if let url = bundle.url(forResource: "Bravura", withExtension: "otf")
                    ?? bundle.url(
                        forResource: "Bravura", withExtension: "otf", subdirectory: "Resources",
                    ),
                    let data = try? Data(contentsOf: url)
                {
                    return data
                }
            }
            return nil
        }

        @Test func canClassifyWithoutCMapIgnoresAnEmbeddedProgramWhenShapeMatchingIsDisabled() {
            guard let bravuraData = Self.loadBravuraOTFData() else { return }
            var font = PDFImporter.EmbeddedFont()
            font.program = bravuraData
            font.programKind = .cff
            let disabled = GlyphClassifier(font: font)
            #expect(!disabled.canClassifyWithoutCMap)
            let enabled = GlyphClassifier(font: font, enableShapeMatching: true)
            #expect(enabled.canClassifyWithoutCMap)
        }

        /// The test this round is really about: with `enableShapeMatching`
        /// left at its default (false), a glyph that only Tier 4 could ever
        /// resolve — a real Bravura noteheadBlack outline, reached by its
        /// own raw glyph ID under an unrelated codepoint neither Tier 1 nor
        /// Tier 2 can name — stays `.unknown`. This is what stops a future
        /// change from silently flipping Tier 4 on by default.
        @Test func shapeMatchingDisabledLeavesAGlyphOnlyTier4CouldResolveUnknown() {
            guard let bravuraData = Self.loadBravuraOTFData() else { return }
            guard let ctFont = makeCTFont(program: bravuraData, kind: .cff) else { return }
            var unichars: [UniChar] = [0xE0A4] // noteheadBlack
            var glyphs: [CGGlyph] = [0]
            guard CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, 1),
                  glyphs[0] != 0
            else { return }
            let noteheadGlyphID = glyphs[0]

            var font = PDFImporter.EmbeddedFont()
            font.program = bravuraData
            font.programKind = .cff

            // Codepoint 0x41 ("A") is neither a SMuFL PUA codepoint (Tier 1)
            // nor named in `/Differences` (Tier 2, empty here) — only Tier 4,
            // reading the real noteheadBlack outline by raw glyph ID, could
            // ever resolve it.
            let disabled = GlyphClassifier(font: font)
            #expect(disabled.classify(codepoint: 0x41, glyphID: noteheadGlyphID) == .unknown(0x41))

            // Prove the setup isn't vacuous: the same font/glyph DOES resolve
            // once Tier 4 is explicitly turned on.
            let enabled = GlyphClassifier(font: font, enableShapeMatching: true)
            #expect(enabled.classify(codepoint: 0x41, glyphID: noteheadGlyphID) == .noteheadBlack)
        }
    }
#endif
