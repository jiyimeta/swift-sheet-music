#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    import Testing

    /// Embedded-font-program extraction, on a SYNTHETIC fixture.
    ///
    /// `PDFFontProgramTests` and
    /// `GlyphBitmapTests.buildsCTFontFromAnchorEmbeddedProgram` assert the
    /// same pipeline — `extractEmbeddedFonts` → `/FontFile*` bytes →
    /// `makeCTFont` → real outlines — but only against
    /// `~/Desktop/pdf_test/ギブス.pdf`, a copyrighted file that cannot be
    /// committed. On CI they `return` before asserting. This file covers the
    /// same path with a PDF built in memory, so the extraction that Tier 4
    /// and the music-font gate both stand on is actually verified somewhere.
    ///
    /// It also covers a case the corpus anchor does not: that fixture embeds
    /// Leland (CFF) only, whereas this one carries BOTH program kinds — a
    /// CFF music face and a TrueType text face — so a regression in either
    /// `/FontFile2` or `/FontFile3` handling is caught.
    @MainActor struct PDFSyntheticFontProgramTests {
        private static var bravuraAvailable: Bool {
            guard #available(macOS 15.0, *) else { return false }
            return BravuraFont.register
        }

        /// One glyph from each face is enough: CoreGraphics embeds the
        /// subset that the drawn glyphs require, and the assertions below
        /// are about the program being retrievable and parseable, not about
        /// its size.
        private static func twoFaceFixture() -> Data {
            PDFFixtureBuilder.build(
                glyphs: [
                    PDFFixtureBuilder.GlyphPlacement(
                        unicodeScalar: "\u{E0A4}", // noteheadBlack
                        fontName: "Bravura", fontSize: 32,
                        origin: CGPoint(x: 100, y: 700),
                    ),
                    PDFFixtureBuilder.GlyphPlacement(
                        unicodeScalar: "a", fontName: "Helvetica",
                        fontSize: 12, origin: CGPoint(x: 100, y: 650),
                    ),
                ],
            )
        }

        private static func embeddedFonts(
            in data: Data,
        ) throws -> [String: PDFImporter.EmbeddedFont] {
            let doc = try PDFImporter.openDocument(data)
            let cgPage = try #require(doc.page(at: 0)?.pageRef)
            return PDFImporter.extractEmbeddedFonts(cgPage: cgPage)
        }

        @Test func extractsBaseFontAndProgramFromBothProgramKinds() throws {
            guard Self.bravuraAvailable else { return }
            let fonts = try Self.embeddedFonts(in: Self.twoFaceFixture())
            #expect(!fonts.isEmpty)

            let withProgram = fonts.values.filter { $0.program != nil }
            #expect(!withProgram.isEmpty)
            for f in withProgram {
                #expect(!f.baseFont.isEmpty)
                #expect(f.programKind != nil)
            }

            // Both kinds present — the coverage the corpus anchor lacks.
            let kinds = Set(withProgram.compactMap(\.programKind))
            #expect(kinds.contains(.cff))
            #expect(kinds.contains(.trueType))
        }

        /// The embedded program must round-trip to a usable `CTFont` whose
        /// glyphs have real outlines — the precondition for every Tier-4
        /// descriptor and every music-font-gate sample. A program that
        /// extracts but yields only empty paths would leave both silently
        /// answering nothing.
        @Test func buildsCTFontWithRealOutlinesFromEmbeddedProgram() throws {
            guard Self.bravuraAvailable else { return }
            let fonts = try Self.embeddedFonts(in: Self.twoFaceFixture())
            // Target the music face DETERMINISTICALLY — Dictionary iteration
            // order is unspecified. Subset-embedded faces are renamed
            // "ABCDEF+Bravura", so match the suffix after any "+".
            let music = try #require(fonts.values.first { f in
                (f.baseFont.split(separator: "+").last.map(String.init) ?? f.baseFont)
                    == "Bravura"
            })
            let program = try #require(music.program)
            _ = try #require(music.programKind)
            let font = try #require(makeCTFont(program: program))

            let count = CTFontGetGlyphCount(font)
            #expect(count > 0)
            var nonEmptyOutlines = 0
            for g in 1 ..< count {
                if let path = CTFontCreatePathForGlyph(font, CGGlyph(g), nil), !path.isEmpty {
                    nonEmptyOutlines += 1
                }
            }
            #expect(nonEmptyOutlines > 0)
        }

        /// The `uniXXXX` glyph names in `/Encoding /Differences` are what
        /// Tier 2 resolves on the simple-font path, and they are the only
        /// reason the synthetic gate fixture classifies at all. Pin them:
        /// if CoreGraphics ever switched to synthetic `gNN` names, the gate
        /// tests would go quiet rather than fail.
        @Test func embedsMusicGlyphsUnderResolvableUniNames() throws {
            guard Self.bravuraAvailable else { return }
            let fonts = try Self.embeddedFonts(in: Self.twoFaceFixture())
            let music = try #require(fonts.values.first { f in
                (f.baseFont.split(separator: "+").last.map(String.init) ?? f.baseFont)
                    == "Bravura"
            })
            #expect(music.differences.values.contains("uniE0A4"))
        }
    }
#endif
