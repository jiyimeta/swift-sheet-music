#if !os(Android)
    @testable import SheetMusicLayout
    import Testing

    struct NoteheadGlyphTests {
        @Test func xcircleNowRenders() {
            let cp = NoteheadGlyph.codepoint(duration: .quarter, headType: "xcircle", stemUp: false)
            #expect(cp == SMuFLCodepoint.noteheadCircleX)
            #expect(cp != SMuFLCodepoint.noteheadBlack) // no longer falls back
        }

        @Test func unknownStillFallsBack() {
            let cp = NoteheadGlyph.codepoint(
                duration: .quarter, headType: "totally-unknown", stemUp: false,
            )
            #expect(cp == SMuFLCodepoint.noteheadBlack)
        }

        @Test func slashAndShapeNotes() {
            let slashHalf = NoteheadGlyph.codepoint(
                duration: .half, headType: "slash", stemUp: false,
            )
            let doQuarter = NoteheadGlyph.codepoint(
                duration: .quarter, headType: "do", stemUp: false,
            )
            #expect(slashHalf == SMuFLCodepoint.noteheadSlashWhiteHalf)
            #expect(doQuarter == SMuFLCodepoint.noteShapeTriangleUpBlack)
        }
    }
#endif
