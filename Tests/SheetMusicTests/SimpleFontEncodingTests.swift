#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    import Testing

    struct SimpleFontEncodingTests {
        /// The four codes that actually appear in the measured Finale music
        /// stream, and the scalars its subsetted font's cmap answers to.
        @Test func macRomanDecodesTheCodesRealFinaleOutputShows() {
            #expect(SimpleFontEncoding.scalar(code: 0xCF, baseEncoding: "MacRomanEncoding") == "\u{0153}")
            #expect(SimpleFontEncoding.scalar(code: 0xCE, baseEncoding: "MacRomanEncoding") == "\u{0152}")
            #expect(SimpleFontEncoding.scalar(code: 0xE4, baseEncoding: "MacRomanEncoding") == "\u{2030}")
            #expect(SimpleFontEncoding.scalar(code: 0xFA, baseEncoding: "MacRomanEncoding") == "\u{02D9}")
        }

        /// PDF's MacRomanEncoding and Mac OS Roman disagree at exactly one
        /// code. Foundation gives the Mac OS Roman answer (EURO SIGN), the
        /// PDF answer is `currency`.
        @Test func macRomanUsesThePDFMeaningOf0xDB() {
            #expect(SimpleFontEncoding.scalar(code: 0xDB, baseEncoding: "MacRomanEncoding") == "\u{00A4}")
        }

        @Test func asciiIsUnchangedUnderEveryModelledEncoding() {
            for encoding in ["MacRomanEncoding", "WinAnsiEncoding", "StandardEncoding"] {
                #expect(SimpleFontEncoding.scalar(code: 0x41, baseEncoding: encoding) == "A")
                #expect(SimpleFontEncoding.scalar(code: 0x30, baseEncoding: encoding) == "0")
            }
        }

        @Test func winAnsiDecodesItsUpperHalf() {
            #expect(SimpleFontEncoding.scalar(code: 0x92, baseEncoding: "WinAnsiEncoding") == "\u{2019}")
            #expect(SimpleFontEncoding.scalar(code: 0x80, baseEncoding: "WinAnsiEncoding") == "\u{20AC}")
        }

        /// `MacExpertEncoding` has no Latin-1 correspondence at all, so it is
        /// declined rather than approximated — an unresolved code is a miss,
        /// an approximated one would be a wrong glyph.
        @Test func unmodelledEncodingsDecline() {
            #expect(SimpleFontEncoding.scalar(code: 0x41, baseEncoding: "MacExpertEncoding") == nil)
            #expect(SimpleFontEncoding.scalar(code: 0x41, baseEncoding: "") == nil)
            #expect(SimpleFontEncoding.scalar(code: 0x41, baseEncoding: "Identity-H") == nil)
        }

        @Test func codesOutsideAByteDecline() {
            #expect(SimpleFontEncoding.scalar(code: 0x100, baseEncoding: "MacRomanEncoding") == nil)
        }
    }

    /// `GlyphClassifier.resolveGlyphID` — the character-code → glyph-ID step
    /// that stood between real legacy-font PDFs and Tier 4.
    ///
    /// Bravura is the only embedded-font program available without the
    /// developer's local PDF corpus, and its cmap reaches exactly two codes
    /// under `MacRomanEncoding` (measured: 32 and 202, both the space
    /// glyph). That is thin, but it is a REAL font's real cmap, and it is
    /// enough to pin both outcomes: the code that resolves, and the code
    /// that must not.
    struct GlyphIDResolveTests {
        private static func bravuraData() -> Data? {
            // Touching `BravuraFont.register` is what actually loads the
            // `SheetMusicLayoutApple` resource bundle into this process; a
            // bare `import` does not, so without this the bundle search
            // below finds nothing whenever no other suite happens to have
            // registered the font first, and every test here silently
            // passes on an empty guard.
            if #available(macOS 15.0, *) { _ = BravuraFont.register }
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

        private static func glyphID(_ ctFont: CTFont, _ scalar: Unicode.Scalar) -> CGGlyph? {
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(ctFont, &units, &glyphs, units.count),
                  let gid = glyphs.first, gid != 0 else { return nil }
            return gid
        }

        private static func embeddedBravura(baseEncoding: String) -> PDFImporter.EmbeddedFont? {
            guard let data = bravuraData() else { return nil }
            var font = PDFImporter.EmbeddedFont()
            font.program = data
            font.programKind = .cff
            font.baseEncoding = baseEncoding
            return font
        }

        /// The strategy real Finale output needs: the DECLARED base encoding
        /// decodes the code to a scalar, and the font's own cmap answers it.
        /// Self-configuring — it asks the font which code it can answer, so
        /// it does not hard-code which Latin glyphs Bravura happens to ship.
        @Test func declaredBaseEncodingResolvesThroughTheFontsCmap() {
            guard let font = Self.embeddedBravura(baseEncoding: "MacRomanEncoding"),
                  let program = font.program, let ctFont = makeCTFont(program: program)
            else { return }
            var probe: (code: UInt32, gid: CGGlyph)?
            for code in UInt32(0x20) ... 0xFF {
                guard let scalar = SimpleFontEncoding.scalar(
                    code: code, baseEncoding: "MacRomanEncoding",
                ), let gid = Self.glyphID(ctFont, scalar) else { continue }
                probe = (code, gid)
                break
            }
            let resolved = try? #require(probe)
            #expect(probe != nil, "Bravura's cmap answers no MacRoman code — setup is vacuous")
            guard let resolved else { return }
            let c = GlyphClassifier(font: font)
            #expect(c.resolveGlyphID(code: resolved.code) == resolved.gid)
        }

        /// A code the font's cmap does NOT answer must resolve to nil.
        ///
        /// This is the assertion that keeps an identity fallback out: 0x41
        /// under `MacRomanEncoding` is `A`, and Bravura has no `A`, so the
        /// only readings left are "unresolved" or "glyph 65" — an unrelated
        /// outline Tier 4 would then confidently name. An earlier revision
        /// returned 65.
        @Test func aCodeTheCmapCannotAnswerResolvesToNil() {
            guard let font = Self.embeddedBravura(baseEncoding: "MacRomanEncoding"),
                  let program = font.program, let ctFont = makeCTFont(program: program),
                  Self.glyphID(ctFont, "A") == nil // setup guard: Bravura really has no `A`
            else { return }
            let c = GlyphClassifier(font: font)
            #expect(c.resolveGlyphID(code: 0x41) == nil)
        }

        /// A `/Differences` NAME does not resolve a glyph ID on its own, and
        /// nothing tries to make it: `CTFontGetGlyphWithName` measured 0 for
        /// `noteheadBlack` against full, unsubsetted Bravura, whose CFF
        /// charset certainly carries that name. Tier 2 answers such a code
        /// from the name directly and never needed the glyph ID.
        @Test func differencesNameAloneDoesNotResolveAGlyphID() {
            guard var font = Self.embeddedBravura(baseEncoding: "MacRomanEncoding")
            else { return }
            font.differences = [0x41: "noteheadBlack"]
            let c = GlyphClassifier(font: font)
            #expect(c.resolveGlyphID(code: 0x41) == nil)
            // ... while Tier 2 still classifies that code correctly.
            #expect(
                c.classify(codepoint: 0x41, characterCode: 0x41, glyphID: nil) == .noteheadBlack,
            )
        }

        @Test func resolutionIsStableAcrossRepeatedLookups() {
            guard let font = Self.embeddedBravura(baseEncoding: "MacRomanEncoding") else { return }
            let c = GlyphClassifier(font: font)
            let first = c.resolveGlyphID(code: 0x20)
            #expect(c.resolveGlyphID(code: 0x20) == first)
        }

        @Test func noEmbeddedProgramResolvesToNil() {
            let c = GlyphClassifier(font: PDFImporter.EmbeddedFont())
            #expect(c.resolveGlyphID(code: 0x41) == nil)
        }
    }
#endif
