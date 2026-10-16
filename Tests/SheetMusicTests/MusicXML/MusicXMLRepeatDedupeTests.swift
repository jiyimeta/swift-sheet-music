import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import SheetMusicXMLTools
import Testing

/// One repeat per direction (`MusicXmlParserDirection::handleRepeats`,
/// `importexport/musicxml/internal/import/importmusicxmlpass2.cpp:~4652-4773`), and where it stands.
@Suite("MusicXML repeat classification")
struct MusicXMLRepeatDedupeTests {
    private typealias F = DirectionFixtures

    private static func decode(_ xml: String) throws -> MusicXMLJumpDecoder.Decoded {
        try MusicXMLJumpDecoder.decode(XMLTreeParser.parse(Data(xml.utf8)))
    }

    private static func markers(_ score: Score, measure: Int = 0) -> [Marker] {
        score.parts[0].staves[0].measures[measure].markers
    }

    private static func jumps(_ score: Score, measure: Int = 0) -> [Jump] {
        score.parts[0].staves[0].measures[measure].jumps
    }

    /// MuseScore hides a repeat with no text (`setVisible(false)`) and then sets the direction's own visibility over it
    /// (`tb->setVisible(m_visible)`, P2 ~4769), so a textless repeat stays visible and prints its default text.
    @Test("a repeat with no text at all stays visible (P2 ~4769)")
    func noTextStaysVisible() throws {
        let decoded = try Self.decode("<direction><direction-type/><sound tocoda=\"coda\"/></direction>")
        #expect(decoded.markers.count == 1)
        #expect(decoded.markers.first?.elementProperties.visible == true)
    }

    private static let sounds: [(String, String)] = [("tocoda=\"coda\"", "coda"), ("fine=\"yes\"", "fine")]

    @Test("a D.S. is a jump only: the other attributes steer it and make no marker", arguments: sounds)
    func dalSegnoMakesOnlyAJump(extra: String, playUntil: String) throws {
        let decoded = try Self.decode(
            "<direction><direction-type><words>D.S. al Coda</words></direction-type>"
                + "<sound dalsegno=\"segno\" \(extra)/></direction>",
        )
        #expect(decoded.markers.isEmpty)
        #expect(decoded.jumps.count == 1)
        #expect(decoded.jumps.first?.jumpTo == "segno")
        #expect(decoded.jumps.first?.playUntil == playUntil)
    }

    @Test("a second coda in a bar is discarded (P2:4709-4712)")
    func secondCodaInABarIsDiscarded() throws {
        let coda = F.direction("<coda/>", "<sound coda=\"codab\"/>")
        let score = try F.score(measures: [coda + coda + F.fourQuarters])
        #expect(Self.markers(score).count == 1)
    }

    @Test("two segnos at one tick are one Segno labeled segnoii (P2 ~4718-4730)")
    func twoSegnosAtOneTickMerge() throws {
        let segno = F.direction("<segno/>", "<sound segno=\"segno\"/>")
        let score = try F.score(measures: [segno + segno + F.fourQuarters])
        let markers = Self.markers(score)
        #expect(markers.count == 1)
        #expect(markers.first?.kind == .segno)
        #expect(markers.first?.label == "segnoii")
    }

    @Test("a jump's words are not also a staff text")
    func jumpWordsAreNotAlsoText() throws {
        let body = F.direction(F.words("D.S."), "<sound dalsegno=\"segno\"/>") + F.fourQuarters
        let score = try F.score(measures: [body])
        #expect(Self.jumps(score).count == 1)
        #expect(F.lane(score).isEmpty)
    }

    private static let rightItems: [(String, Bool)] = [
        ("<words>Fine</words><sound fine=\"yes\"/>", true), ("<words>D.C.</words><sound dacapo=\"yes\"/>", false),
    ]

    @Test("a bar-end item written at the next bar's start belongs to the previous bar", arguments: rightItems)
    func rightItemMovesBack(inner: String, isMarker: Bool) throws {
        let types = inner.components(separatedBy: "<sound")
        let direction = F.direction(types[0], "<sound" + types[1])
        let score = try F.score(measures: [F.fourQuarters, direction + F.fourQuarters])
        #expect(Self.markers(score, measure: 0).count == (isMarker ? 1 : 0))
        #expect(Self.jumps(score, measure: 0).count == (isMarker ? 0 : 1))
        #expect(Self.markers(score, measure: 1).isEmpty)
        #expect(Self.jumps(score, measure: 1).isEmpty)
    }

    @Test("a bar-start item written at the bar's end belongs to the next bar")
    func leftItemMovesForward() throws {
        let segno = F.direction("<segno/>", "<sound segno=\"segno\"/>")
        let score = try F.score(measures: [F.fourQuarters + segno, F.fourQuarters])
        #expect(Self.markers(score, measure: 0).isEmpty)
        #expect(Self.markers(score, measure: 1).map(\.kind) == [.segno])
    }
}
