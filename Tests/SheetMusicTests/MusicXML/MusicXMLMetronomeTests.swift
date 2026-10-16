import Foundation
@testable import SheetMusicMusicXML
import SheetMusicXMLTools
import Testing

/// `<metronome>` → MuseScore's text and the tempo it implies (`MusicXmlParserDirection::metronome`, `P2:5594-5659`;
/// `TempoText::duration2tempoTextString`, `tempotext.cpp:173-218`).
@Suite("MusicXML metronome")
struct MusicXMLMetronomeTests {
    private static let cases: [(String, String, Double)] = [
        ("<beat-unit>quarter</beat-unit><per-minute>120</per-minute>", "<sym>metNoteQuarterUp</sym> = 120", 120),
        (
            "<beat-unit>quarter</beat-unit><beat-unit-dot/><per-minute>80</per-minute>",
            "<sym>metNoteQuarterUp</sym><sym>space</sym><sym>metAugmentationDot</sym> = 80", 120,
        ),
        ("<beat-unit>half</beat-unit><per-minute>60</per-minute>", "<sym>metNoteHalfUp</sym> = 60", 120),
        (
            "<beat-unit>eighth</beat-unit><per-minute>200</per-minute>", "<sym>metNote8thUp</sym> = 200", 100,
        ),
        (
            "<beat-unit>quarter</beat-unit><beat-unit>eighth</beat-unit>",
            "<sym>metNoteQuarterUp</sym> = <sym>metNote8thUp</sym>", 0,
        ),
        ("<per-minute>90</per-minute>", " = 90", 0),
    ]

    @Test("each shape gives its text and tempo", arguments: cases)
    func parses(body: String, text: String, bpm: Double) throws {
        let node = try XMLTreeParser.parse(Data("<metronome>\(body)</metronome>".utf8))
        let parsed = MusicXMLMetronome.parse(node)
        #expect(parsed.xmlText == text)
        #expect(parsed.quarterBeatsPerMinute == bpm)
    }

    @Test("parentheses wrap the text")
    func parentheses() throws {
        let markup = "<metronome parentheses=\"yes\"><beat-unit>quarter</beat-unit>"
            + "<per-minute>96</per-minute></metronome>"
        let parsed = try MusicXMLMetronome.parse(XMLTreeParser.parse(Data(markup.utf8)))
        #expect(parsed.xmlText == "(<sym>metNoteQuarterUp</sym> = 96)")
        #expect(parsed.quarterBeatsPerMinute == 96)
    }
}
