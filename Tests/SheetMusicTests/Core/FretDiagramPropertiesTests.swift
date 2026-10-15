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

    private static func fingerprint(_ diagram: FretDiagram) -> UInt64 {
        var hasher = FNV1a()
        hasher.combine(diagram)
        return hasher.value
    }

    /// The bytes `combine(_ diagram:)` fed for a one-barre diagram before barres became a list, written out by hand.
    private static func legacyOneBarreBytes(_ barre: FretBarre) -> UInt64 {
        var legacy = FNV1a()
        legacy.combine(6)
        legacy.combine(5)
        legacy.combine(0)
        legacy.combine(true)
        legacy.combine(barre.startString)
        legacy.combine(barre.endString)
        legacy.combine(barre.fret)
        legacy.combine(false)
        legacy.combineOccupied(ElementProperties.default, visibleTag: 58, colorTag: 59, placementTag: 79)
        return legacy.value
    }

    @Test("a one-barre diagram feeds the fingerprint the bytes it always did; a second barre adds its own")
    func fingerprintBarres() {
        let barre = FretBarre(startString: 1, endString: 5, fret: 1)
        let single = FretDiagram(barres: [barre])
        #expect(Self.fingerprint(single) == Self.legacyOneBarreBytes(barre))
        var double = single
        double.barres.append(FretBarre(startString: 2, endString: 3, fret: 2))
        #expect(Self.fingerprint(double) != Self.fingerprint(single))
    }

    /// No edit writes the offset, the nut or the orientation, and a client that predates them kept them as preserved
    /// markup: hashing them could only make two versions disagree about one file.
    @Test("offset, nut and orientation stay out of the fingerprint")
    func fingerprintLeavesFrameOut() {
        let barre = FretBarre(startString: 1, endString: 5, fret: 1)
        let framed = FretDiagram(barres: [barre], fretOffset: 3, showNut: false, orientation: .horizontal)
        #expect(Self.fingerprint(framed) == Self.legacyOneBarreBytes(barre))
        let bare = FretDiagram(fretOffset: 3, showNut: false, orientation: .horizontal)
        #expect(Self.fingerprint(bare) == FNV1a().value)
    }

    @Test("the one-barre accessor reads and writes the first barre only")
    func firstBarreAccessor() {
        var diagram = FretDiagram()
        diagram.barre = FretBarre(startString: 1, endString: 5, fret: 1)
        #expect(diagram.barres == [FretBarre(startString: 1, endString: 5, fret: 1)])
        diagram.barres.append(FretBarre(startString: 2, endString: 3, fret: 2))
        diagram.barre = FretBarre(startString: 0, endString: -1, fret: 4)
        #expect(diagram.barres.count == 2)
        diagram.barre = nil
        #expect(diagram.barres == [FretBarre(startString: 2, endString: 3, fret: 2)])
    }
}
