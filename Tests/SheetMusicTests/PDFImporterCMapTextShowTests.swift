#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// Unit tests for the Type0 / CMap show path — the `emitShow` branch
    /// taken whenever `activeCMap` is non-empty, which is EVERY score in the
    /// corpus (all MuseScore output carries a `/ToUnicode`).
    ///
    /// These pin where a text run's origin is recorded. The path used to
    /// read `currentOrigin` at FLUSH time, i.e. after the loop had already
    /// advanced the text matrix past the run's own codes, so every run was
    /// stored one approximate advance to the right of its ink. The argument
    /// for tolerating it was that MuseScore emits one BT/ET block per glyph,
    /// making a run a single code and the error "small" — but one advance is
    /// `fontSize * 0.5 * ctmScale`, 3.0pt on 君とParadiso, which was enough
    /// to push a tuplet digit clear of its own bracket arm.
    ///
    /// The corpus could not catch this: it measures note/lyric accuracy, and
    /// a uniform shift of every text run is close to invisible there. It has
    /// to be pinned at the walker.
    struct PDFImporterCMapTextShowTests {
        /// CIDs 1 and 2 are ordinary text; CID 3 is a SMuFL PUA notehead, so
        /// it routes to the music stream and splits a text run.
        private static let noteheadPUA: Unicode.Scalar = "\u{E0A4}"

        private func pageState(fontSize: CGFloat = 30) -> PDFPageState {
            let state = PDFPageState(pageIndex: 0)
            state.fontSize = fontSize
            state.activeCMap = PDFImporter.ToUnicodeCMap(table: [
                1: ["3"],
                2: ["6"],
                3: [Self.noteheadPUA],
            ])
            return state
        }

        /// Identity-H is 2 bytes per CID.
        private func cid(_ value: UInt16) -> [UInt8] {
            [UInt8(value >> 8), UInt8(value & 0xFF)]
        }

        /// THE REGRESSION GUARD. The production case: MuseScore emits one
        /// BT/ET block per glyph, so a real tuplet digit is a ONE-CODE run.
        /// Its origin must be where the digit starts, not one advance later.
        @Test func singleCodeRunIsRecordedAtItsStartNotOneAdvanceLater() {
            let state = pageState(fontSize: 30)
            emitShow(cid(1), state: state)
            #expect(state.texts.count == 1)
            let glyph = try? #require(state.texts.first)
            #expect(glyph?.text == "3")
            // advance = fontSize * 0.5 = 15. The run began at x = 0, so 0 is
            // correct and 15 is the old flush-time bug.
            #expect(abs((glyph?.origin.x ?? .nan) - 0) < 0.001)
        }

        /// A multi-code run must also land at its first code.
        @Test func multiCodeRunIsRecordedAtItsFirstCode() {
            let state = pageState(fontSize: 30)
            emitShow(cid(1) + cid(2), state: state)
            #expect(state.texts.count == 1)
            let glyph = try? #require(state.texts.first)
            #expect(glyph?.text == "36")
            // Two advances consumed (30pt), but the run started at 0.
            #expect(abs((glyph?.origin.x ?? .nan) - 0) < 0.001)
        }

        /// A text run following a music glyph starts after that glyph's
        /// advance — proving the fix records the run's own start rather than
        /// simply pinning every run to the show string's origin.
        @Test func textRunAfterAMusicGlyphStartsAfterThatGlyph() {
            let state = pageState(fontSize: 30)
            emitShow(cid(3) + cid(1), state: state)
            #expect(state.glyphs.count == 1)
            #expect(state.texts.count == 1)
            let glyph = try? #require(state.texts.first)
            #expect(glyph?.text == "3")
            // The notehead consumed one 15pt advance, so the digit starts
            // at 15 — not 0 (show-string origin) and not 30 (flush time).
            #expect(abs((glyph?.origin.x ?? .nan) - 15) < 0.001)
        }

        /// Two runs split by a music glyph keep distinct, correct origins.
        @Test func twoRunsSplitByAMusicGlyphKeepDistinctOrigins() {
            let state = pageState(fontSize: 30)
            emitShow(cid(1) + cid(3) + cid(2), state: state)
            #expect(state.texts.count == 2)
            let first = try? #require(state.texts.first)
            let second = try? #require(state.texts.last)
            #expect(first?.text == "3")
            #expect(second?.text == "6")
            #expect(abs((first?.origin.x ?? .nan) - 0) < 0.001)
            // digit, notehead → two advances → the second run starts at 30.
            #expect(abs((second?.origin.x ?? .nan) - 30) < 0.001)
        }

        /// The recorded origin must be the run's start in PAGE space, so the
        /// CTM has to be applied to it. Mirrors the real corpus, where the
        /// export CTM is 0.2 (MuseScore engraves at 360 DPI).
        @Test func originIsInPageSpaceUnderANonIdentityCTM() {
            let state = pageState(fontSize: 30)
            state.ctmStack = [CGAffineTransform(scaleX: 0.2, y: 0.2)]
            emitShow(cid(3) + cid(1), state: state)
            let glyph = try? #require(state.texts.first)
            // The notehead's 15pt text-space advance is 3.0pt on the page —
            // exactly the 君とParadiso bias that defeated bracketSpan.
            #expect(abs((glyph?.origin.x ?? .nan) - 3.0) < 0.001)
            // And the page-space em is the Tf operand through the CTM.
            #expect(abs((glyph?.renderedSize ?? .nan) - 6.0) < 0.001)
        }
    }
#endif
