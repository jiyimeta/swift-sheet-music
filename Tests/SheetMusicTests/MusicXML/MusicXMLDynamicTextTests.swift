@testable import SheetMusicMusicXML
import Testing

/// `Dynamic::parseDynamicText` for a MusicXML `<other-dynamics>`: the first known dynamic token (a run of
/// `f m n p r s z` standing alone between non-word characters) is the subtype; whatever else the text holds is the
/// dynamic's own words, with the token spelled as its glyphs. MuseScore's `<sym>` alternative (a text that already
/// spells a dynamic as its glyphs, escaped in the MusicXML) is read too.
@Suite("MusicXML dynamic text")
struct MusicXMLDynamicTextTests {
    private static let cases: [(String, String, String?)] = [
        ("p", "p", nil),
        ("mf", "mf", nil),
        ("sfz", "sfz", nil),
        ("fp", "fp", nil),
        ("n", "n", nil),
        ("subito p", "p", "subito <sym>dynamicPiano</sym>"),
        ("più f", "f", "più <sym>dynamicForte</sym>"),
        ("subito pp", "pp", "subito <sym>dynamicPiano</sym><sym>dynamicPiano</sym>"),
        ("molto sfz.", "sfz", "molto <sym>dynamicSforzando</sym><sym>dynamicForte</sym><sym>dynamicZ</sym>."),
        ("ad lib.", "other-dynamics", nil),
    ]

    @Test("a token is the subtype and the rest is the dynamic's words", arguments: cases)
    func parses(tag: String, subtype: String, custom: String?) {
        let parsed = MusicXMLDynamicText.parse(tag)
        #expect(parsed.subtype == subtype)
        #expect(parsed.customXML == custom)
    }

    @Test("Finale's letters are dynamics only when the exporter is Finale (P2:4519-4528)")
    func finaleLetters() {
        #expect(MusicXMLDynamicText.wordsDynamic("π", finale: true) == "pp")
        #expect(MusicXMLDynamicText.wordsDynamic("S", finale: true) == "sf")
        #expect(MusicXMLDynamicText.wordsDynamic("π", finale: false) == nil)
        #expect(MusicXMLDynamicText.wordsDynamic("S", finale: false) == nil)
    }
}
