import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// MusicXML `<fermata>` shapes against MuseScore's import (`convertFermataToSymId`, `importmusicxmlpass2.cpp:1516`)
/// and its hold: `addFermataToChord` calls `setSymIdAndTimeStretch`, which gives the subtype's FILE default — the
/// value an absent `<timeStretch>` means in an MSCX file, not the one folino's menu inserts.
@Suite("Fermata MusicXML import")
struct FermataImportTests {
    private static func fermata(shape: String, type: String = "upright") throws -> Fermata? {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>G</sign><line>2</line></clef>
              </attributes>
              <note>
                <pitch><step>C</step><octave>5</octave></pitch>
                <duration>4</duration><voice>1</voice><type>whole</type>
                <notations><fermata type="\(type)">\(shape)</fermata></notations>
              </note>
            </measure>
          </part>
        </score-partwise>
        """
        let score = try MusicXMLParser.parse(Data(xml.utf8))
        for element in score.parts[0].staves[0].measures[0].voices[0].elements {
            if case let .fermata(fermata) = element { return fermata }
        }
        return nil
    }

    @Test("every shape maps to MuseScore's subtype and its file-default hold")
    func shapes() throws {
        let cases: [(shape: String, subtype: String, stretch: Double)] = [
            ("", "fermataAbove", 2.0),
            ("normal", "fermataAbove", 2.0),
            ("angled", "fermataShortAbove", 1.5),
            ("square", "fermataLongAbove", 3.0),
            ("double-angled", "fermataVeryShortAbove", 1.25),
            ("double-square", "fermataVeryLongAbove", 4.0),
            ("double-dot", "fermataLongHenzeAbove", 3.0),
            ("half-curve", "fermataShortHenzeAbove", 1.5),
        ]
        for (shape, subtype, stretch) in cases {
            let fermata = try #require(try Self.fermata(shape: shape), "shape '\(shape)'")
            #expect(fermata.subtype == subtype, "shape '\(shape)'")
            #expect(fermata.timeStretch == stretch, "shape '\(shape)'")
        }
    }

    @Test("an inverted fermata takes the Below subtype with the same hold")
    func inverted() throws {
        let fermata = try #require(try Self.fermata(shape: "half-curve", type: "inverted"))
        #expect(fermata.subtype == "fermataShortHenzeBelow")
        #expect(fermata.timeStretch == 1.5)
    }
}
