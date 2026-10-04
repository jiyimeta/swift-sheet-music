import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

/// MuseScore keeps two types on every clef — the one Concert Pitch shows and the one the written view shows — and
/// reads a `<Clef>` that names only the first with the second left at `ClefTypeList`'s default, G
/// (`rw/read460/tread.cpp`, `TRead::read(Clef*)`). Its written view is the default view, so a bass clef folino wrote
/// as `<concertClefType>F</concertClefType>` alone opened in MuseScore as a treble clef.
@Suite("Clef transposing type in MSCX")
struct ClefTransposingTypeMSCXTests {
    private func reparsed(_ clef: Clef) throws -> (xml: XMLTreeNode, clef: Clef) {
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [clef.encode(eid: .invalid)]))
        let node = try #require(XMLTreeParser.parse(bytes).first("Clef"))
        return try (node, Clef.decode(node))
    }

    @Test func clefWithNoTransposingTypeWritesItsConcertTypeForBoth() throws {
        let (xml, _) = try reparsed(Clef(concertClefType: "F"))
        #expect(xml.first("concertClefType")?.text == "F")
        #expect(xml.first("transposingClefType")?.text == "F")
    }

    @Test func distinctTransposingTypeIsWrittenAndReadBack() throws {
        let clef = Clef(concertClefType: "F8vb", transposingClefType: "F8va")
        let (xml, decoded) = try reparsed(clef)
        #expect(xml.first("transposingClefType")?.text == "F8va")
        #expect(decoded == clef)
    }

    /// Two equal types say no more than one: the model keeps `nil` for "the same in both views", so a clef folino
    /// wrote reads back equal to itself — and so does a MuseScore clef, which always names both.
    @Test func equalTypesReadBackAsNoTransposingType() throws {
        let (_, decoded) = try reparsed(Clef(concertClefType: "C3"))
        #expect(decoded == Clef(concertClefType: "C3"))
        let museScoreClef = try Clef.decode(XMLTreeNode(name: "Clef", children: [
            XMLTreeNode(name: "concertClefType", text: "G8vb"),
            XMLTreeNode(name: "transposingClefType", text: "G8vb"),
        ]))
        #expect(museScoreClef.transposingClefType == nil)
        #expect(museScoreClef.writtenClefType == "G8vb")
    }
}
