import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

/// `<lastSystemFillLimit>` is MuseScore's `Sid::lastSystemFillLimit` (`style/styledef.cpp:279`, default 0.3): the
/// fill below which the line a piece or a section ends on is left at its natural width. A score that sets it to 0
/// has every last line justified, and was drawn with its last line short until the style was read.
@Suite("Last system fill limit style")
struct LastSystemFillLimitStyleTests {
    @Test("the fill limit is read off <Style>")
    func fillLimitIsRead() throws {
        let xml = "<Style><lastSystemFillLimit>0</lastSystemFillLimit></Style>"
        let style = try ScoreStyle.decode(style: XMLTreeParser.parse(Data(xml.utf8)))
        #expect(style.lastSystemFillLimit == 0)
    }

    @Test("a style without the tag keeps MuseScore's default")
    func absentFillLimitKeepsTheDefault() throws {
        let style = try ScoreStyle.decode(style: XMLTreeParser.parse(Data("<Style></Style>".utf8)))
        #expect(style.lastSystemFillLimit == 0.3)
        #expect(ScoreStyle.museScoreDefaults.lastSystemFillLimit == 0.3)
    }

    /// The value is read for layout and the tag stays preserved markup, so a save writes back what the file said.
    @Test("a score's fill limit is read and still saved")
    func fillLimitSurvivesASave() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("testMidiPort"))
        #expect(score.style.lastSystemFillLimit == 0)
        let text = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(text.contains("<lastSystemFillLimit>0</lastSystemFillLimit>"))
    }
}
