import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// The fret diagram's offset, nut, orientation and every barre are modeled, and an absent tag stays absent.
@Suite("Fret diagram offset, nut, orientation and barres")
struct FretDiagramPropertiesTests {
    private static func diagrams(_ name: String) throws -> [FretDiagram] {
        try AnnotationFixtures.load(name).parts.flatMap(\.staves).flatMap(\.measures).flatMap(\.voices)
            .flatMap(\.elements)
            .compactMap { element -> FretDiagram? in
                if case let .fretDiagram(diagram) = element { diagram } else { nil }
            }
    }

    private static func xml(_ score: Score) throws -> String {
        try #require(String(bytes: MSCXEncoder.encode(score), encoding: .utf8))
    }

    @Test("w5-diagrams: offset 2, nut on, two barres; the second diagram horizontal with none of those tags")
    func modeled() throws {
        let diagrams = try Self.diagrams("w5-diagrams")
        try #require(diagrams.count == 2)
        #expect(diagrams[0].fretOffset == 2)
        #expect(diagrams[0].showNut == true)
        #expect(diagrams[0].barres == [
            FretBarre(startString: 2, endString: 5, fret: 1), FretBarre(startString: 3, endString: 4, fret: 3),
        ])
        #expect(diagrams[0].barre == diagrams[0].barres.first)
        #expect(diagrams[1].orientation == .horizontal)
        #expect(diagrams[1].fretOffset == nil && diagrams[1].showNut == nil && diagrams[1].barres.isEmpty)
    }

    @Test("the fixture with explicit defaults keeps them: fretOffset 0, showNut 1, orientation 0")
    func absentStaysAbsent() throws {
        let diagrams = try Self.diagrams("fret-diagrams")
        try #require(diagrams.count == 2)
        #expect(diagrams[0].fretOffset == 0 && diagrams[0].showNut == true && diagrams[0].orientation == .vertical)
        #expect(diagrams[1].fretOffset == nil && diagrams[1].showNut == false)
    }

    @Test("both barres are written back, in fret order, the properties before <fretDiagram> in MuseScore's order")
    func roundTrip() throws {
        let xml = try Self.xml(AnnotationFixtures.load("w5-diagrams"))
        #expect(xml.components(separatedBy: "<barre ").count == 3)
        #expect(xml.contains("<fretOffset>2</fretOffset>"))
        #expect(xml.contains("<orientation>1</orientation>"))
        let again = try Self.xml(MSCXParser.parse(Data(xml.utf8)))
        #expect(again == xml)
        let defaults = try Self.xml(AnnotationFixtures.load("fret-diagrams"))
        #expect(defaults.contains("<fretOffset>0</fretOffset>") && defaults.contains("<showNut>1</showNut>"))
        // MuseScore's reader skips every child after <fretDiagram>: the properties it reads come first.
        let order = [
            "<minDistance>",
            "<fretOffset>",
            "<frets>",
            "<strings>",
            "<showNut>",
            "<mag>",
            "<orientation>",
            "<fretDiagram>",
        ]
        let positions = order.compactMap { defaults.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count)
        #expect(positions == positions.sorted())
    }

    @Test("the fingerprint input of a one-barre diagram is the one it always had")
    func oneBarreEquality() {
        var single = FretDiagram(strings: [], barres: [FretBarre(startString: 1, endString: 5, fret: 1)])
        var legacy = FretDiagram()
        legacy.barre = FretBarre(startString: 1, endString: 5, fret: 1)
        #expect(single == legacy)
        single.barres.append(FretBarre(startString: 2, endString: 3, fret: 2))
        #expect(single != legacy)
        legacy.barre = nil
        #expect(legacy.barres.isEmpty)
    }
}
