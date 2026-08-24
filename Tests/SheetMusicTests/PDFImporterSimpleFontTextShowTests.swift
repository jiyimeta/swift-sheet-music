#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// Unit tests for the simple-font (no `/ToUnicode`, 1-byte code) show
    /// path — `emitShowSimpleFont`, reached through `emitShow` whenever the
    /// active classifier reports `canClassifyWithoutCMap`.
    ///
    /// The corpus cannot cover this path: every corpus PDF is MuseScore
    /// output with a proper CMap. These drive the walker's page state
    /// directly instead.
    struct PDFImporterSimpleFontTextShowTests {
        /// A classifier over a font whose `/Differences` names ONE music
        /// glyph, so `canClassifyWithoutCMap` is true and the byte path runs,
        /// while ordinary bytes still fall through to text.
        private func classifier(
            differences: [UInt32: String] = [0x51: "noteheadBlack"],
        ) -> GlyphClassifier {
            var font = PDFImporter.EmbeddedFont()
            font.differences = differences
            return GlyphClassifier(font: font)
        }

        private func pageState(fontSize: CGFloat = 10) -> PDFPageState {
            let state = PDFPageState(pageIndex: 0)
            state.fontSize = fontSize
            state.activeClassifier = classifier()
            return state
        }

        @Test func textRunLandsAtItsStartNotItsEnd() {
            let state = pageState()
            // "ABC" — no code is in /Differences, so all three are text.
            emitShow([0x41, 0x42, 0x43], state: state)
            let text = try? #require(state.texts.first)
            #expect(state.texts.count == 1)
            #expect(text?.text == "ABC")
            // The run STARTS at the text position the run began at (x = 0),
            // not at the position the matrix reached after advancing past
            // all three bytes (x = 3 × fontSize × 0.5 = 15).
            #expect(abs((text?.origin.x ?? .nan) - 0) < 0.001)
        }

        @Test func textRunAfterAMusicGlyphStartsAfterThatGlyph() {
            let state = pageState()
            // 0x51 is the notehead; "AB" follows it.
            emitShow([0x51, 0x41, 0x42], state: state)
            #expect(state.glyphs.count == 1)
            let text = try? #require(state.texts.first)
            #expect(text?.text == "AB")
            // One music glyph consumed one advance (5pt), so the text run
            // begins at x = 5 — not at 15 (after all three advances).
            #expect(abs((text?.origin.x ?? .nan) - 5) < 0.001)
        }

        @Test func twoTextRunsSplitByAMusicGlyphKeepDistinctOrigins() {
            let state = pageState()
            emitShow([0x41, 0x51, 0x42], state: state)
            #expect(state.texts.count == 2)
            #expect(state.texts.map(\.text) == ["A", "B"])
            #expect(abs(state.texts[0].origin.x - 0) < 0.001)
            #expect(abs(state.texts[1].origin.x - 10) < 0.001)
        }

        /// The damage I2 describes, end to end: a re-encoded TEXT font whose
        /// `/Differences` names its digits the AGL way must keep "2024" as
        /// TEXT. Promoted to music it would become four time-signature digits
        /// — a fabricated time signature and a fabricated mm-rest count — and
        /// vanish from the title it belongs to.
        @Test func digitsOfATextFontStayText() {
            let state = PDFPageState(pageIndex: 0)
            state.fontSize = 10
            state.activeClassifier = classifier(differences: [
                0x30: "zero", 0x31: "one", 0x32: "two", 0x34: "four",
                0x41: "A", 0x20: "space",
            ])
            emitShow([0x32, 0x30, 0x32, 0x34], state: state)
            #expect(state.glyphs.isEmpty)
            #expect(state.texts.map(\.text) == ["2024"])
        }

        /// A byte no tier classifies is TEXT, and a simple font's text bytes
        /// are character codes in its own encoding — not Latin-1. The real
        /// Finale files declare `MacRomanEncoding`, where 0xD5 is `’`.
        @Test func unclassifiedBytesDecodeThroughTheDeclaredEncoding() {
            let state = pageState()
            state.activeSimpleFontDecoder = SimpleFontTextDecoder(
                differences: [:], baseEncoding: "MacRomanEncoding",
            )
            emitShow([0xD5], state: state)
            #expect(state.texts.map(\.text) == ["\u{2019}"])
        }

        /// The same font seen WITHOUT a classifier — Tier 4 off, nothing in
        /// `/Differences` — takes the whole-run path, which must honor the
        /// declared encoding too. This is the path the real Finale text
        /// fonts actually take.
        @Test func aFontWithoutAClassifierStillDecodesThroughItsEncoding() {
            let state = PDFPageState(pageIndex: 0)
            state.fontSize = 10
            state.activeSimpleFontDecoder = SimpleFontTextDecoder(
                differences: [:], baseEncoding: "MacRomanEncoding",
            )
            emitShow([0x41, 0xD5, 0x42], state: state)
            #expect(state.texts.map(\.text) == ["A\u{2019}B"])
        }

        /// A font that declares no usable encoding keeps the legacy whole-run
        /// decode — UTF-8 first. The ASCII test fixtures and every Identity-H
        /// font depend on it.
        @Test func aFontWithNoDeclaredEncodingKeepsTheLegacyDecode() {
            let state = PDFPageState(pageIndex: 0)
            state.fontSize = 10
            emitShow([0xC3, 0xA9], state: state)
            #expect(state.texts.map(\.text) == ["\u{00E9}"])
        }

        @Test func musicGlyphOriginIsUnaffected() {
            let state = pageState()
            emitShow([0x41, 0x51], state: state)
            let glyph = try? #require(state.glyphs.first)
            // The notehead is the second code, so it sits one advance in.
            #expect(abs((glyph?.geometry.origin.x ?? .nan) - 5) < 0.001)
        }
    }
#endif
