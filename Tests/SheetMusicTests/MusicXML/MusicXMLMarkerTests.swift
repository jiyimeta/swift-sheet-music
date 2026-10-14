import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import SheetMusicXMLTools
import Testing

/// MusicXML's segno and coda glyphs and its `<sound>` hints, named the way MuseScore's importer names them
/// (`MusicXmlParserDirection::findMarker`, `importexport/musicxml/internal/import/importmusicxmlpass2.cpp:4772-4796`).
@Suite("MusicXML markers")
struct MusicXMLMarkerTests {
    private static func decode(_ xml: String) throws -> MusicXMLJumpDecoder.Decoded {
        try MusicXMLJumpDecoder.decode(XMLTreeParser.parse(Data(xml.utf8)))
    }

    @Test("a coda glyph is a Coda, labeled `codab` unless <sound> names it otherwise")
    func coda() throws {
        let named = try Self.decode(
            "<direction><direction-type><coda/></direction-type><sound coda=\"codab\"/></direction>",
        )
        #expect(named.markers == [Marker(kind: .coda, label: "codab")])
        let bare = try Self.decode("<direction><direction-type><coda/></direction-type></direction>")
        #expect(bare.markers == [Marker(kind: .coda, label: "codab")])
        let varcoda = try Self.decode(
            "<direction><direction-type><coda/></direction-type><sound coda=\"varcoda\"/></direction>",
        )
        #expect(varcoda.markers.map(\.kind) == [.varcoda])
    }

    @Test("a segno glyph is a Segno, or MuseScore's variant when <sound> names it")
    func segno() throws {
        let plain = try Self.decode("<direction><direction-type><segno/></direction-type></direction>")
        #expect(plain.markers == [Marker(kind: .segno, label: "segno")])
        let variant = try Self.decode(
            "<direction><direction-type><segno/></direction-type><sound segno=\"varsegno\"/></direction>",
        )
        #expect(variant.markers == [Marker(kind: .varsegno, label: "varsegno")])
    }

    @Test("MuseScore's own export marks the variants with smufl, which wins over the <sound> label")
    func smuflVariants() throws {
        let serpent = try Self.decode(
            "<direction><direction-type><segno smufl=\"segnoSerpent1\"/></direction-type>"
                + "<sound segno=\"x\"/></direction>",
        )
        #expect(serpent.markers == [Marker(kind: .varsegno, label: "x")])
        let square = try Self.decode(
            "<direction><direction-type><coda smufl=\"codaSquare\"/></direction-type></direction>",
        )
        #expect(square.markers == [Marker(kind: .varcoda, label: "varcoda")])
        // A label naming a different kind loses to the glyph's own smufl name.
        let conflicting = try Self.decode(
            "<direction><direction-type><coda smufl=\"codaSquare\"/></direction-type>"
                + "<sound coda=\"codetta\"/></direction>",
        )
        #expect(conflicting.markers.map(\.kind) == [.varcoda])
    }

    /// Pins today's output for one `<direction>` carrying both; a later pass that dedupes the two replaces it.
    @Test("a <coda/> glyph with <sound tocoda> yields a Coda and a To Coda")
    func codaGlyphWithToCoda() throws {
        let decoded = try Self.decode(
            "<direction><direction-type><coda/></direction-type><sound tocoda=\"coda\"/></direction>",
        )
        #expect(decoded.markers == [
            Marker(kind: .coda, label: "codab"),
            Marker(kind: .toCoda, label: "coda", text: "To Coda"),
        ])
        #expect(decoded.jumps.isEmpty)
    }

    @Test("<sound tocoda> is a To Coda, not a Coda")
    func toCoda() throws {
        let decoded = try Self.decode(
            "<direction><direction-type><words>To Coda</words></direction-type><sound tocoda=\"coda\"/></direction>",
        )
        #expect(decoded.markers == [Marker(kind: .toCoda, label: "coda", text: "To Coda")])
    }
}
