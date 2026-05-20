@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("FlagGlyph")
struct FlagGlyphTests {
    @Test func eighthFlagPicksDirectionVariant() {
        #expect(
            FlagGlyph.codepoint(duration: .eighth, stem: .up)
                == SMuFLCodepoint.flag8thUp,
        )
        #expect(
            FlagGlyph.codepoint(duration: .eighth, stem: .down)
                == SMuFLCodepoint.flag8thDown,
        )
    }

    @Test func sixteenthThroughSixtyFourthAreMapped() {
        #expect(
            FlagGlyph.codepoint(duration: .sixteenth, stem: .up)
                == SMuFLCodepoint.flag16thUp,
        )
        #expect(
            FlagGlyph.codepoint(duration: .thirtySecond, stem: .down)
                == SMuFLCodepoint.flag32ndDown,
        )
        #expect(
            FlagGlyph.codepoint(duration: .sixtyFourth, stem: .up)
                == SMuFLCodepoint.flag64thUp,
        )
    }

    @Test func stemlessAndBeamableDurationsAreNil() {
        #expect(FlagGlyph.codepoint(duration: .whole, stem: .up) == nil)
        #expect(FlagGlyph.codepoint(duration: .half, stem: .down) == nil)
        #expect(FlagGlyph.codepoint(duration: .quarter, stem: .up) == nil)
    }
}
