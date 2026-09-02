#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    @testable import SheetMusicCore
    import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    import Testing

    struct GlyphClassifierTests {
        @Test func tier1SMuFLCodepointWinsWhenPresent() {
            let c = GlyphClassifier(font: nil)
            #expect(c.classify(codepoint: 0xE0A4, characterCode: 0xE0A4, glyphID: nil) == .noteheadBlack)
            #expect(c.classify(codepoint: 0xE050, characterCode: 0xE050, glyphID: nil) == .clefG)
        }

        @Test func tier2GlyphNameResolvesNonSMuFLCodepoint() {
            var font = PDFImporter.EmbeddedFont()
            font.baseFont = "ABCDEF+Maestro"
            font.differences = [0x6E: "quarterrest", 0x77: "sharp"]
            let c = GlyphClassifier(font: font)
            // 0x6E is not a SMuFL PUA codepoint, so Tier 1 cannot fire.
            #expect(c.classify(codepoint: 0x6E, characterCode: 0x6E, glyphID: nil) == .rest(.quarter))
            #expect(c.classify(codepoint: 0x77, characterCode: 0x77, glyphID: nil) == .accidentalSharp)
        }

        @Test func unresolvableCodepointStaysUnknown() {
            let c = GlyphClassifier(font: nil)
            #expect(c.classify(codepoint: 0x41, characterCode: 0x41, glyphID: nil) == .unknown(0x41))
        }

        @Test func tier1IsUnaffectedByAnEmbeddedFont() {
            var font = PDFImporter.EmbeddedFont()
            font.differences = [0xE0A4: "quarterrest"] // deliberately wrong
            let c = GlyphClassifier(font: font)
            // Tier 1 must win — a SMuFL codepoint is authoritative.
            #expect(c.classify(codepoint: 0xE0A4, characterCode: 0xE0A4, glyphID: nil) == .noteheadBlack)
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

        // MARK: Tier 2 text-ambiguous names (AGL digit words)

        /// `/Differences [48 /zero /one /two …]` is the ORDINARY way any
        /// producer — TeX, Word, Finale, Sibelius — names the digits of a
        /// re-encoded TEXT font. Tier 2 must not read those as time-signature
        /// digits: doing so invents a time signature, invents a
        /// multi-measure-rest count, and drops the digits out of the title /
        /// lyric text they belong to.
        @Test func bareDigitNamesInATextFontStayUnknown() {
            var font = PDFImporter.EmbeddedFont()
            font.baseFont = "ABCDEF+TimesNewRoman"
            font.differences = [
                0x30: "zero", 0x31: "one", 0x32: "two", 0x33: "three",
                0x41: "A", 0x61: "a", 0x20: "space",
            ]
            let c = GlyphClassifier(font: font)
            #expect(c.classify(codepoint: 0x32, characterCode: 0x32, glyphID: nil) == .unknown(0x32))
            #expect(c.classify(codepoint: 0x34, characterCode: 0x34, glyphID: nil) == .unknown(0x34))
        }

        /// The same bare digit name IS a time-signature digit once the font
        /// identifies itself as a music font by naming a glyph only a music
        /// font has. This is what keeps a legacy music face (whose digits
        /// really are `/zero`…`/nine`) working.
        @Test func bareDigitNamesResolveInAFontThatAlsoNamesMusicGlyphs() {
            var font = PDFImporter.EmbeddedFont()
            font.baseFont = "ABCDEF+Maestro"
            font.differences = [
                0x30: "zero", 0x34: "four", 0x51: "noteheadBlack", 0x6E: "quarterrest",
            ]
            let c = GlyphClassifier(font: font)
            #expect(
                c.classify(codepoint: 0x34, characterCode: 0x34, glyphID: nil)
                    == .timeSignatureDigit(4),
            )
        }

        /// `timeSig4` is unambiguous — no text font names a glyph that — so
        /// it never needs the music-font evidence.
        @Test func smuflTimeSigDigitNamesResolveUnconditionally() {
            var font = PDFImporter.EmbeddedFont()
            font.differences = [0x34: "timeSig4"]
            let c = GlyphClassifier(font: font)
            #expect(
                c.classify(codepoint: 0x34, characterCode: 0x34, glyphID: nil)
                    == .timeSignatureDigit(4),
            )
        }

        /// `/Differences` is keyed by CHARACTER CODE. The CMap path has a
        /// Unicode scalar, not a character code, so it must not index the
        /// map at all — the two only ever coincide over ASCII, which is
        /// exactly where a spurious hit does the most damage.
        @Test func differencesAreNotConsultedWithoutACharacterCode() {
            var font = PDFImporter.EmbeddedFont()
            font.differences = [0x6E: "quarterrest"]
            let c = GlyphClassifier(font: font)
            #expect(c.classify(codepoint: 0x6E, characterCode: nil, glyphID: nil) == .unknown(0x6E))
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
            // Touching `BravuraFont.register` is what loads the
            // `SheetMusicLayoutApple` resource bundle into this process — a
            // bare dependency does not. Without it this search finds nothing
            // unless some other test in this run happened to register the
            // font first, so every caller's `guard … else { return }` would
            // pass vacuously depending on scheduling order (measured: the
            // whole file passes empty when run under a narrow `--filter`).
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
            guard let ctFont = makeCTFont(program: bravuraData) else { return }
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
            #expect(disabled.classify(codepoint: 0x41, characterCode: 0x41, glyphID: noteheadGlyphID) == .unknown(0x41))

            // Prove the setup isn't vacuous: the same font/glyph DOES resolve
            // once Tier 4 is explicitly turned on.
            let enabled = GlyphClassifier(font: font, enableShapeMatching: true)
            #expect(enabled.classify(codepoint: 0x41, characterCode: 0x41, glyphID: noteheadGlyphID) == .noteheadBlack)
        }

        /// Two DIFFERENT glyph IDs presented under the SAME codepoint must
        /// classify independently. A subsetted font routinely decodes several
        /// CIDs to one Unicode scalar (unmapped CIDs collapse onto a single
        /// scalar, and `.notdef`-adjacent codes share one), so a
        /// codepoint-only cache would answer the second glyph with the
        /// first's outline verdict — for Tier 4, whose answer depends on
        /// nothing BUT the outline, that is simply the wrong semantic.
        @Test func shapeMatchingDistinguishesTwoGlyphIDsUnderOneCodepoint() {
            guard let bravuraData = Self.loadBravuraOTFData(),
                  let ctFont = makeCTFont(program: bravuraData)
            else { return }
            func glyphID(_ codepoint: UniChar) -> CGGlyph? {
                var unichars: [UniChar] = [codepoint]
                var glyphs: [CGGlyph] = [0]
                guard CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, 1),
                      glyphs[0] != 0 else { return nil }
                return glyphs[0]
            }
            guard let notehead = glyphID(0xE0A4), let clef = glyphID(0xE050)
            else { return }

            var font = PDFImporter.EmbeddedFont()
            font.program = bravuraData
            font.programKind = .cff
            let c = GlyphClassifier(font: font, enableShapeMatching: true)

            // Codepoint 0x41 reaches neither Tier 1 nor Tier 2, so both
            // answers come from Tier 4 — i.e. from the glyph ID alone.
            #expect(c.classify(codepoint: 0x41, characterCode: 0x41, glyphID: notehead) == .noteheadBlack)
            #expect(c.classify(codepoint: 0x41, characterCode: 0x41, glyphID: clef) == .clefG)
        }

        /// The cache must still serve a repeat of the same (codepoint, glyph
        /// ID) pair — the whole reason it exists.
        @Test func repeatedGlyphIDUnderOneCodepointStaysStable() {
            guard let bravuraData = Self.loadBravuraOTFData(),
                  let ctFont = makeCTFont(program: bravuraData)
            else { return }
            var unichars: [UniChar] = [0xE0A4]
            var glyphs: [CGGlyph] = [0]
            guard CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, 1),
                  glyphs[0] != 0 else { return }

            var font = PDFImporter.EmbeddedFont()
            font.program = bravuraData
            font.programKind = .cff
            let c = GlyphClassifier(font: font, enableShapeMatching: true)
            let first = c.classify(codepoint: 0x41, characterCode: 0x41, glyphID: glyphs[0])
            #expect(c.classify(codepoint: 0x41, characterCode: 0x41, glyphID: glyphs[0]) == first)
        }

        /// The whole/half rest pair used to be Tier 4's one UNRESOLVABLE
        /// collision: the same rectangle in Bravura, byte-identical after
        /// normalization, answered `.rest(.whole)` by a documented guess.
        ///
        /// `ShapeDescriptor.emBottom` resolves it — the whole rest hangs below
        /// its line, the half rest sits above it, a 0.5-space difference every
        /// SMuFL font agrees on. A real Bravura `restHalf` outline must now
        /// come back as a HALF rest, and its sibling as a whole rest.
        @Test func aHalfRestOutlineClassifiesAsAHalfRest() {
            guard let bravuraData = Self.loadBravuraOTFData(),
                  let ctFont = makeCTFont(program: bravuraData)
            else { return }
            var unichars: [UniChar] = [0xE4E4, 0xE4E3] // restHalf, restWhole
            var glyphs: [CGGlyph] = [0, 0]
            guard CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, 2),
                  glyphs[0] != 0, glyphs[1] != 0 else { return }

            var font = PDFImporter.EmbeddedFont()
            font.program = bravuraData
            font.programKind = .cff
            let c = GlyphClassifier(font: font, enableShapeMatching: true)
            #expect(
                c.classify(codepoint: 0x41, characterCode: 0x41, glyphID: glyphs[0])
                    == .rest(.half),
            )
            // The sibling must not have moved with it — an exemplar-order
            // artifact would answer the same semantic for both.
            #expect(
                c.classify(codepoint: 0x42, characterCode: 0x42, glyphID: glyphs[1])
                    == .rest(.whole),
            )
        }

        // MARK: Music-font gate (`isLikelyMusicFont`, Task 15 final review C2)

        /// Direct coverage for `isLikelyMusicFont` — it had NONE before this
        /// round, which is exactly how the bug it guards against shipped: a
        /// FULL (unsubsetted) music font sampled mostly exotic, non-
        /// exemplar-shaped glyphs under the old evenly-strided-glyph-ID
        /// population and scored 0.20, well under the 0.5 acceptance
        /// fraction — rejecting Bravura, the very font its own exemplars
        /// are rendered from. No corpus dependency (registers the bundled
        /// Bravura.otf via `BravuraFont`, the SAME mechanism
        /// `BravuraExemplars` itself uses to build its reference
        /// descriptors), so this runs in CI.
        @Test func isLikelyMusicFontAcceptsTheBundledBravuraFont() {
            guard #available(macOS 15.0, *), BravuraFont.register else { return }
            let ctFont = CTFontCreateWithName(BravuraFont.familyName as CFString, 1000, nil)
            #expect(GlyphClassifier.isLikelyMusicFont(ctFont: ctFont))
        }

        /// The companion negative: an ordinary system text font must stay
        /// REJECTED — proving `isLikelyMusicFontAcceptsTheBundledBravuraFont`
        /// isn't passing merely because the gate now accepts everything.
        @Test func isLikelyMusicFontRejectsASystemTextFont() {
            let ctFont = CTFontCreateWithName("Helvetica" as CFString, 1000, nil)
            #expect(!GlyphClassifier.isLikelyMusicFont(ctFont: ctFont))
        }
    }
#endif
