import Foundation
@testable import SheetMusicMusicXML
import SheetMusicXMLTools
import Testing

/// `<words>` attributes become MuseScore xml text (`nextPartOfFormattedString`, `P2:835-911`); characters are escaped
/// as `String::toXmlEscaped` does (`framework/global/types/string.cpp:1282-1316`).
@Suite("MusicXML formatted words")
struct MusicXMLFormattedWordsTests {
    private static let cases: [(String, String)] = [
        ("<words>Solo</words>", "Solo"),
        ("<words font-weight=\"bold\">Solo</words>", "<b>Solo</b>"),
        ("<words font-weight=\"bold\" font-style=\"italic\">Solo</words>", "<b><i>Solo</i></b>"),
        ("<words underline=\"1\" line-through=\"2\">Solo</words>", "<u><s>Solo</s></u>"),
        ("<words font-size=\"12\" font-family=\"Times\">Solo</words>", "<font size=\"12\"/><font face=\"Times\"/>Solo"),
        ("<words>a &amp; b</words>", "a &amp; b"),
        ("<words>a\r\nb</words>", "a\nb"),
        // The tree trims `text` when an element closes; MuseScore keeps the space (`testTempoTextSpace1_ref.mscx`).
        ("<words>Surreptitiously </words>", "Surreptitiously "),
        ("<words font-weight=\"bold\">Surreptitiously </words>", "<b>Surreptitiously </b>"),
    ]

    @Test("each attribute becomes its tag, in MuseScore's order", arguments: cases)
    func xmlText(markup: String, expected: String) throws {
        let node = try XMLTreeParser.parse(Data(markup.utf8), preservingMixedContentIn: ["words", "rehearsal"])
        #expect(MusicXMLFormattedWords.xmlText(of: node) == expected)
    }

    @Test("simplified collapses whitespace like QString::simplified")
    func simplified() {
        #expect(MusicXMLFormattedWords.simplified("  a \n b\u{00A0}c ") == "a b c")
    }

    @Test("a plain text carries no markup and a formatted one does")
    func carrier() {
        let plain = MusicXMLFormattedWords.carrier(fromXMLText: "Solo &amp; co")
        #expect(plain.plain == "Solo & co")
        #expect(plain.markup == nil)
        let bold = MusicXMLFormattedWords.carrier(fromXMLText: "<b>Solo</b>")
        #expect(bold.plain == "Solo")
        #expect(bold.markup != nil)
    }
}
