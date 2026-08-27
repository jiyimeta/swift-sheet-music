#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct GlyphNameTableTests {
        @Test func mapsCanonicalSMuFLNames() {
            #expect(GlyphNameTable.semantic(glyphName: "gClef") == .clefG)
            #expect(GlyphNameTable.semantic(glyphName: "fClef") == .clefF)
            #expect(GlyphNameTable.semantic(glyphName: "noteheadBlack") == .noteheadBlack)
            #expect(GlyphNameTable.semantic(glyphName: "noteheadHalf") == .noteheadHalf)
            #expect(GlyphNameTable.semantic(glyphName: "accidentalSharp") == .accidentalSharp)
            #expect(GlyphNameTable.semantic(glyphName: "restQuarter") == .rest(.quarter))
            #expect(GlyphNameTable.semantic(glyphName: "rest16th") == .rest(.sixteenth))
            #expect(GlyphNameTable.semantic(glyphName: "brace") == .brace)
        }

        @Test func mapsLegacyPostScriptNames() {
            #expect(GlyphNameTable.semantic(glyphName: "quarterrest") == .rest(.quarter))
            #expect(GlyphNameTable.semantic(glyphName: "sharp") == .accidentalSharp)
            #expect(GlyphNameTable.semantic(glyphName: "flat") == .accidentalFlat)
            #expect(GlyphNameTable.semantic(glyphName: "natural") == .accidentalNatural)
        }

        @Test func isCaseAndSuffixInsensitive() {
            #expect(GlyphNameTable.semantic(glyphName: "NoteheadBlack") == .noteheadBlack)
            #expect(GlyphNameTable.semantic(glyphName: "uniE0A4") == .noteheadBlack)
        }

        @Test func returnsNilForUnknownNames() {
            #expect(GlyphNameTable.semantic(glyphName: "g123") == nil)
            #expect(GlyphNameTable.semantic(glyphName: "") == nil)
        }

        // MARK: - readDifferences hardening (Step 4b)
        //
        // Every font in the corpus anchor (ギブス.pdf) has an EMPTY
        // `/Encoding /Differences`, so nothing in the corpus exercises the
        // alternating start-code / name-run parse. These synthetic tests
        // are the only safety net for `parseDifferencesTokens` — the
        // off-by-one-prone code-increment continuation extracted from
        // `PDFImporter.readDifferences`.

        @Test func parsesMultiRunDifferencesTokens() {
            // Mirrors the PDF array `[ 32 /space /exclam 48 /zero /one ]`:
            // a start-code token followed by a run of name tokens, twice.
            let tokens: [(code: Int?, name: String?)] = [
                (32, nil), (nil, "space"), (nil, "exclam"),
                (48, nil), (nil, "zero"), (nil, "one"),
            ]
            let result = PDFImporter.parseDifferencesTokens(tokens)
            #expect(result[32] == "space")
            #expect(result[33] == "exclam")
            #expect(result[48] == "zero")
            #expect(result[49] == "one")
            #expect(result.count == 4)
        }

        @Test func skipsNegativeStartCodeWithoutTrapping() {
            // A malformed `/Differences` such as `[ -1 /space ]`. The
            // negative start-code must be skipped (not cast to UInt32,
            // which would trap) — the parser degrades rather than crashes.
            let tokens: [(code: Int?, name: String?)] = [(-1, nil), (nil, "space")]
            let result = PDFImporter.parseDifferencesTokens(tokens)
            #expect(result.count == 1)
            #expect(result[0] == "space")
        }
    }
#endif
