@testable import SheetMusicLayout
import Testing

/// The SMuFL names MuseScore writes inside `<sym>` and as symbol subtypes resolve through `SMuFLCodepoint.byName`
/// (`Tools/smufl/glyphnames-text-symbols.json`). Codepoints are SMuFL facts (`fonts/smufl/glyphnames.json`).
@Suite("SMuFL names MuseScore writes in text")
struct SMuFLTextSymbolNameTests {
    @Test(arguments: [
        ("keyboardPedalPed", UInt32(0xE650)), ("coda", 0xE048), ("segnoSerpent1", 0xE04A), ("codaSquare", 0xE049),
        ("dynamicForte", 0xE522), ("dynamicPiano", 0xE520), ("metNoteQuarterUp", 0xECA5),
        ("metAugmentationDot", 0xECB7), ("fermataAbove", 0xE4C0), ("caesura", 0xE4D1),
        ("harpPedalRaised", 0xE680), ("fretboard3String", 0xE850), ("figbass0", 0xEA50),
        ("articAccentAbove", 0xE4A0), ("textBlackNoteShortStem", 0xE1F0),
    ])
    func resolvesByName(name: String, codepoint: UInt32) {
        #expect(SMuFLCodepoint.byName(name) == codepoint)
    }

    @Test("a name in no table resolves to nil")
    func unknownNameIsNil() {
        #expect(SMuFLCodepoint.byName("notASymbolName") == nil)
    }

    @Test("a name that is also a hand-written constant resolves to the same codepoint")
    func agreesWithConstants() {
        #expect(SMuFLCodepoint.byName("segno") == SMuFLCodepoint.segno)
        #expect(SMuFLCodepoint.byName("coda") == SMuFLCodepoint.coda)
        #expect(SMuFLCodepoint.byName("fermataAbove") == SMuFLCodepoint.fermataAbove)
    }
}
