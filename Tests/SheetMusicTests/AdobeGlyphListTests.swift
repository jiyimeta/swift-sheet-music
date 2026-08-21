#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// `AdobeGlyphList` — glyph NAME → the text it stands for, for the
    /// `/Encoding /Differences` half of the simple-font text decode.
    struct AdobeGlyphListTests {
        @Test func standardNamesResolveToTheirScalar() {
            #expect(AdobeGlyphList.text(forGlyphName: "A") == "A")
            #expect(AdobeGlyphList.text(forGlyphName: "eacute") == "\u{00E9}")
            #expect(AdobeGlyphList.text(forGlyphName: "quoteright") == "\u{2019}")
            #expect(AdobeGlyphList.text(forGlyphName: "emdash") == "\u{2014}")
            #expect(AdobeGlyphList.text(forGlyphName: "Euro") == "\u{20AC}")
        }

        /// The AGL algorithm's `uniXXXX` form, including the multi-scalar
        /// spelling a ligature name uses.
        @Test func uniFormCarriesTheCodepointDirectly() {
            #expect(AdobeGlyphList.text(forGlyphName: "uni00E9") == "\u{00E9}")
            #expect(AdobeGlyphList.text(forGlyphName: "uni00660069") == "fi")
        }

        @Test func uFormCarriesTheCodepointDirectly() {
            #expect(AdobeGlyphList.text(forGlyphName: "u00E9") == "\u{00E9}")
            #expect(AdobeGlyphList.text(forGlyphName: "u01FC") == "\u{01FC}")
        }

        /// `name.variant` — a stylistic-alternate suffix names the same
        /// character, so it decodes to the same text.
        @Test func aVariantSuffixIsStripped() {
            #expect(AdobeGlyphList.text(forGlyphName: "eacute.sc") == "\u{00E9}")
            #expect(AdobeGlyphList.text(forGlyphName: "one.oldstyle") == "1")
        }

        @Test func ligatureComponentsAreJoined() {
            #expect(AdobeGlyphList.text(forGlyphName: "f_i") == "fi")
            #expect(AdobeGlyphList.text(forGlyphName: "f_f_l") == "ffl")
        }

        /// A ligature whose components do not all resolve decodes to nothing
        /// rather than to a truncated word.
        @Test func aPartlyUnresolvableLigatureDeclines() {
            #expect(AdobeGlyphList.text(forGlyphName: "f_gid12") == nil)
        }

        /// Subsetting replaces real names with synthetic ones. They carry no
        /// character and must not be guessed at.
        @Test func syntheticSubsetNamesDecline() {
            #expect(AdobeGlyphList.text(forGlyphName: "g23") == nil)
            #expect(AdobeGlyphList.text(forGlyphName: "gid12") == nil)
            #expect(AdobeGlyphList.text(forGlyphName: "cid5") == nil)
            #expect(AdobeGlyphList.text(forGlyphName: "index7") == nil)
            #expect(AdobeGlyphList.text(forGlyphName: "") == nil)
        }

        /// A MUSIC glyph name is not an AGL name. Tier 2 answers those; this
        /// table must not invent text for one.
        @Test func musicGlyphNamesDecline() {
            #expect(AdobeGlyphList.text(forGlyphName: "noteheadBlack") == nil)
            #expect(AdobeGlyphList.text(forGlyphName: "gClef") == nil)
        }

        @Test func surrogateCodepointsDecline() {
            #expect(AdobeGlyphList.text(forGlyphName: "uniD800") == nil)
        }
    }
#endif
