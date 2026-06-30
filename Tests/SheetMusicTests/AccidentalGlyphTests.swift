#if !os(Android)
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    struct AccidentalGlyphTests {
        @Test func standardUnchanged() {
            #expect(AccidentalGlyph.codepoint(.sharp) == 0xE262)
            #expect(AccidentalGlyph.codepoint(.doubleFlat) == 0xE264)
        }

        @Test func quarterToneMapsToSmuflName() {
            #expect(AccidentalGlyph.codepoint(.mirroredFlat) == SMuFLCodepoint.accidentalQuarterToneFlatStein)
        }

        @Test func enclosureGlyphs() {
            #expect(AccidentalGlyph.enclosure(.none) == nil)
            let p = AccidentalGlyph.enclosure(.parenthesis)
            #expect(p?.left == 0xE26A)
            #expect(p?.right == 0xE26B)
            let b = AccidentalGlyph.enclosure(.bracket)
            #expect(b?.left == 0xE26C)
            #expect(b?.right == 0xE26D)
        }
    }
#endif
