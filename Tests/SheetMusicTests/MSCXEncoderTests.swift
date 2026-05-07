import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder")
struct MSCXEncoderTests {
    @Test("minimal Score round-trips division and metaTags")
    func minimalScoreRoundTrip() throws {
        let original = Score(
            division: 480,
            metaTags: ["composer": "Bach", "workTitle": "Invention"]
        )

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.division == 480)
        #expect(reparsed.metaTags == original.metaTags)
    }

    @Test("Score round-trips custom spatium")
    func spatiumRoundTrip() throws {
        var style = ScoreStyle.museScoreDefaults
        style.spatium = 1.5
        let original = Score(division: 480, style: style)

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.style.spatium == 1.5)
    }

    @Test("Note encodes pitch + tpc and round-trips")
    func noteRoundTrip() throws {
        let note = Note(pitch: 60, tpc: 14)
        let xml = note.encode()
        // re-parse via the full pipeline
        let document = XMLTreeNode(name: "root", children: [xml])
        let bytes = XMLTreeSerializer.serialize(document)
        let reparsed = try XMLTreeParser.parse(bytes)
        let noteNode = try #require(reparsed.first("Note"))
        let decoded = try Note.decode(noteNode)
        #expect(decoded == note)
    }

    @Test("Note round-trips every Accidental case")
    func accidentalRoundTrip() throws {
        let cases: [Accidental] = [.sharp, .flat, .natural, .doubleSharp, .doubleFlat]
        for acc in cases {
            let note = Note(pitch: 61, tpc: 21, accidental: acc)
            let document = XMLTreeNode(name: "root", children: [note.encode()])
            let bytes = XMLTreeSerializer.serialize(document)
            let reparsed = try XMLTreeParser.parse(bytes)
            let noteNode = try #require(reparsed.first("Note"))
            let decoded = try Note.decode(noteNode)
            #expect(decoded.accidental == acc, "accidental \(acc) failed to round-trip")
        }
    }
}
