#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicLayout
    import Testing

    /// The portable bridge is where Android and the browser get their time signatures, so it is the third
    /// renderer that has to agree with the two Apple ones about what a symbol looks like: ONE SMuFL glyph on
    /// the staff middle, not a numerator over a denominator.
    struct LayoutBridgeTimeSignatureTests {
        private let _installApple = TestSupport.installApple

        private func glyphs(
            numerator: Int, denominator: Int, symbol: TimeSignatureSymbol,
        ) -> [(codepoint: UInt32, y: Double)] {
            var out: [DrawCommand] = []
            LayoutBridge.encodeTimeSignature(
                numerator: numerator, denominator: denominator, symbol: symbol,
                originX: 0, originY: 0, sp: 6, glyphSize: 24, into: &out,
            )
            return out.compactMap { command in
                guard case let .glyph(codepoint, _, y, _, _) = command else { return nil }
                return (codepoint, y)
            }
        }

        @Test("a numeric signature is still two rows of digits")
        func numericEmitsDigits() {
            let emitted = glyphs(numerator: 3, denominator: 4, symbol: .numeric)
            #expect(emitted.map(\.codepoint) == [
                SMuFLCodepoint.timeSigDigit(3), SMuFLCodepoint.timeSigDigit(4),
            ])
            // Numerator above the denominator: the two rows straddle the middle they are anchored on.
            #expect(emitted[0].y < emitted[1].y)
        }

        @Test("each symbol is one glyph, and it is the one the layout names")
        func symbolEmitsOneGlyph() {
            let cases: [(TimeSignatureSymbol, Int, Int)] = [
                (.common, 4, 4), (.cutCommon, 2, 2), (.cutBach, 2, 2), (.cutTriple, 9, 8),
            ]
            for (symbol, n, d) in cases {
                let emitted = glyphs(numerator: n, denominator: d, symbol: symbol)
                #expect(emitted.count == 1)
                #expect(emitted.first?.codepoint == TimeSignatureLayout.symbolCodepoint(symbol))
            }
        }

        /// A symbol replaces both rows rather than joining one of them, so it sits between where the two rows
        /// would have been — the staff middle the whole element is anchored on.
        @Test("a symbol sits between the rows it replaces")
        func symbolSitsBetweenTheRows() throws {
            let rows = glyphs(numerator: 4, denominator: 4, symbol: .numeric)
            let symbol = try #require(glyphs(numerator: 4, denominator: 4, symbol: .common).first)
            #expect(rows[0].y < symbol.y)
            #expect(symbol.y < rows[1].y)
        }
    }
#endif
