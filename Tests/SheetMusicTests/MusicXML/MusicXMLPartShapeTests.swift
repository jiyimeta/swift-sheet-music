import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import SheetMusicXMLTools
import Testing

/// What MuseScore's importer adds to a part's shape that the file does not spell out: the implicit brace of a
/// multi-staff part (`P1:1483-1499`) and the explicit normal bar line closing the score (`P2:2109-2118`).
@Suite("MusicXML part shape")
struct MusicXMLPartShapeTests {
    private typealias F = DirectionFixtures

    private static func score(partList: String, measures: String, staves: Int) throws -> Score {
        let stavesTag = staves > 1 ? "<staves>\(staves)</staves>" : ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0"><part-list>\(partList)</part-list>\
        <part id="P1"><measure number="1"><attributes><divisions>480</divisions>\(stavesTag)</attributes>\
        \(measures)</measure></part></score-partwise>
        """
        return try MusicXMLParser.parse(Data(xml.utf8))
    }

    private static let piano = "<score-part id=\"P1\"><part-name>Piano</part-name></score-part>"

    /// MuseScore numbers the brace's column 1 (`bracketLevels + 1`) and draws the empty column 0 at no width; ssm's
    /// gutter gives every column a spatium, so the import compacts the columns and the lone brace sits in column 0.
    @Test("a two-staff part with no part-group gets a brace on its first staff, in column 0")
    func implicitBrace() throws {
        let score = try F.score(measures: [F.whole("C", staff: 1) + "<backup><duration>1920</duration></backup>"
                + F.whole("C", octave: 3, staff: 2)], staves: 2)
        let staves = score.parts[0].staves
        #expect(staves[0].brackets == [BracketItem(type: .brace, span: 2, column: 0)])
        #expect(staves[1].brackets.isEmpty)
    }

    @Test("compacting keeps the columns' order and closes only the gaps")
    func compactedColumns() {
        func staff(_ columns: [Int]) -> Staff {
            Staff(brackets: columns.map { BracketItem(type: .normal, span: 1, column: $0) })
        }
        let parts = [
            Part(id: "1", instrument: Instrument(id: "x"), staves: [staff([1, 3])]),
            Part(id: "2", instrument: Instrument(id: "x"), staves: [staff([3])]),
        ]
        let compacted = Score.canonicalizingBracketColumns(parts)
        #expect(compacted[0].staves[0].brackets.map(\.column) == [0, 1])
        #expect(compacted[1].staves[0].brackets.map(\.column) == [1])
    }

    @Test("a one-staff part gets no brace")
    func noBraceOnOneStaff() throws {
        let score = try F.score(measures: [F.fourQuarters])
        #expect(score.parts[0].staves[0].brackets.isEmpty)
    }

    @Test("a part-group bracketing the part alone replaces the implicit brace; one of a wider span does not")
    func explicitGroup() throws {
        let alone = "<part-group type=\"start\" number=\"1\"><group-symbol>bracket</group-symbol></part-group>"
            + Self.piano + "<part-group type=\"stop\" number=\"1\"/>"
        let notes = F.whole("C", staff: 1)
        #expect(try Self.score(partList: alone, measures: notes, staves: 2).parts[0].staves[0].brackets.isEmpty)
        let noSymbol = "<part-group type=\"start\" number=\"1\"><group-symbol>none</group-symbol></part-group>"
            + Self.piano + "<part-group type=\"stop\" number=\"1\"/>"
        let braced = try Self.score(partList: noSymbol, measures: notes, staves: 2).parts[0].staves[0].brackets
        #expect(braced == [BracketItem(type: .brace, span: 2, column: 0)])
    }

    @Test("groups starting at the part push the brace one column past theirs")
    func braceColumnAfterGroups() throws {
        let list = """
        <part-list><part-group type="start" number="2"><group-symbol>bracket</group-symbol></part-group>\
        <score-part id="P1"/><score-part id="P2"/><part-group type="stop" number="2"/></part-list>
        """
        let groups = try MusicXMLPartGroups(partList: XMLTreeParser.parse(Data(list.utf8)))
        #expect(groups.impliedBraceColumn(partIndex: 0, staffCount: 2) == 2)
        #expect(groups.impliedBraceColumn(partIndex: 1, staffCount: 2) == 1)
        #expect(groups.impliedBraceColumn(partIndex: 0, staffCount: 1) == nil)
    }

    private static func lastElement(_ score: Score) -> VoiceElement? {
        score.parts[0].staves[0].measures.last?.voices[0].elements.values.last
    }

    @Test("a score that ends without a bar line gets MuseScore's explicit normal one")
    func finalNormalBarLine() throws {
        let score = try F.score(measures: [F.fourQuarters, F.fourQuarters])
        #expect(Self.lastElement(score) == .barLine(BarLine()))
        let first = score.parts[0].staves[0].measures[0].voices[0].elements.values.last
        #expect(first.map { element in if case .chord = element { true } else { false } } == true)
    }

    @Test("a styled final bar line or an end repeat is left as it is")
    func styledFinalBarLine() throws {
        let end = "<barline location=\"right\"><bar-style>light-heavy</bar-style></barline>"
        #expect(try Self.lastElement(F.score(measures: [F.fourQuarters + end])) == .barLine(BarLine(subtype: "end")))
        let repeatEnd = "<barline location=\"right\"><repeat direction=\"backward\"/></barline>"
        let repeated = try F.score(measures: [F.fourQuarters + repeatEnd])
        let last = Self.lastElement(repeated)
        #expect(last.map { element in if case .barLine = element { true } else { false } } != true)
    }

    @Test("an <encoding><encoder> is MuseScore's encoder meta tag (testSibOttavas)")
    func encoderMetaTag() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0"><identification><encoding>\
        <encoder>James Mizen</encoder></encoding></identification><part-list>\(Self.piano)</part-list>\
        <part id="P1"><measure number="1"><attributes><divisions>480</divisions></attributes>\
        \(F.whole("C"))</measure></part></score-partwise>
        """
        #expect(try MusicXMLParser.parse(Data(xml.utf8)).metaTags["encoder"] == "James Mizen")
    }
}
