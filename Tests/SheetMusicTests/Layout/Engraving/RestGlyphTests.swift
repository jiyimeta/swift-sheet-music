@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("RestGlyph")
struct RestGlyphTests {
    @Test func measureRestRendersAsWholeRest() {
        // `.measure` is the "this rest fills the measure" marker;
        // MuseScore engraves it as a whole rest.
        let cp = RestGlyph.codepoint(duration: .measure)
        #expect(cp == SMuFLCodepoint.restWhole)
    }

    @Test func wholeAndHalfRestsSwapToLegerLineVariants() {
        #expect(
            RestGlyph.codepoint(duration: .whole, hasLegerLine: true)
                == SMuFLCodepoint.restWholeLegerLine,
        )
        #expect(
            RestGlyph.codepoint(duration: .half, hasLegerLine: true)
                == SMuFLCodepoint.restHalfLegerLine,
        )
        #expect(
            RestGlyph.codepoint(duration: .measure, hasLegerLine: true)
                == SMuFLCodepoint.restWholeLegerLine,
        )
    }

    @Test func standardDurationsMapToTheirOwnGlyphs() {
        #expect(
            RestGlyph.codepoint(duration: .quarter)
                == SMuFLCodepoint.restQuarter,
        )
        #expect(
            RestGlyph.codepoint(duration: .eighth)
                == SMuFLCodepoint.rest8th,
        )
        #expect(
            RestGlyph.codepoint(duration: .sixteenth)
                == SMuFLCodepoint.rest16th,
        )
        #expect(
            RestGlyph.codepoint(duration: .sixtyFourth)
                == SMuFLCodepoint.rest64th,
        )
    }
}
