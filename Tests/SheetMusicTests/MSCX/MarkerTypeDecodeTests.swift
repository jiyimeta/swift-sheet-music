import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

/// A `<Marker>`'s type as the MuseScore reader of the file's own format reads it: `<markerType>` by MuseScore's names
/// from format 4.60 on, absent meaning FINE (`rw/read460/tread.cpp:1700-1726`, `types/typesconv.cpp:3097-3143`);
/// `<label>` before that, SEGNO without one (`rw/read410/tread.cpp:1761-1776`) — and this library's own spellings from
/// before import fidelity W3 read back as what they were saved as.
@Suite("MSCX marker types")
struct MarkerTypeDecodeTests {
    /// One bar holding `markers`, in a `<museScore version="…">` document.
    private static func markers(_ markers: String, version: String? = "4.60") throws -> [Marker] {
        let versionAttribute = version.map { " version=\"\($0)\"" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore\(versionAttribute)><Score><Division>480</Division>
        <Part><Staff id="1"/><Instrument id="piano"><longName>Piano</longName><trackName>Piano</trackName>
        <Channel><program value="0"/></Channel></Instrument></Part>
        <Staff id="1"><Measure>\(markers)
        <voice><TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig><Rest><durationType>measure</durationType>
        <duration>4/4</duration></Rest></voice></Measure></Staff></Score></museScore>
        """
        let score = try MSCXParser.parse(Data(xml.utf8))
        return try #require(score.parts.first?.staves.first?.measures.first).markers
    }

    @Test("MuseScore's format number: major × 100 + minor")
    func formatRevision() {
        #expect(MSCXParserContext.formatRevision(versionAttribute: "4.60") == 460)
        #expect(MSCXParserContext.formatRevision(versionAttribute: "3.01") == 301)
        #expect(MSCXParserContext.formatRevision(versionAttribute: "4.6") == 406)
        #expect(MSCXParserContext.formatRevision(versionAttribute: nil) == nil)
        #expect(MSCXParserContext.formatRevision(versionAttribute: "four") == nil)
    }

    @Test("the name table reads back what it writes; MuseScore 1's Repeat is a To Coda")
    func nameTable() {
        let kinds: [Marker.Kind] = [
            .segno, .varsegno, .coda, .varcoda, .codetta, .fine, .toCoda, .toCodaSym, .daCoda, .daDoubleCoda, .user,
        ]
        for kind in kinds {
            #expect(Marker.Kind(mscxName: kind.mscxName) == kind)
        }
        #expect([Marker.Kind.daCapo, .dalSegno, .other].map(\.mscxName) == ["user", "user", "user"])
        #expect(Marker.Kind.coda.mscxName == "codab" && Marker.Kind.toCoda.mscxName == "coda")
        #expect(Marker.Kind(mscxName: "Repeat") == .toCoda)
        #expect(Marker.Kind(mscxName: "toCoda") == nil)
    }

    @Test("every MuseScore 4.60 type name reads as its kind; an unknown name is Custom (F3.1–F3.3)")
    func museScoreNames() throws {
        let names = [
            "segno", "varsegno", "codab", "varcoda", "codetta", "fine", "coda", "codasym", "dacoda", "dadblcoda",
            "user", "bogus",
        ]
        let xml = names.map { "<Marker><label>x</label><markerType>\($0)</markerType></Marker>" }.joined()
        let kinds = try Self.markers(xml).map(\.kind)
        #expect(kinds == [
            .segno, .varsegno, .coda, .varcoda, .codetta, .fine, .toCoda, .toCodaSym, .daCoda, .daDoubleCoda, .user,
            .user,
        ])
    }

    @Test("a 4.60 marker without <markerType> is a Fine, whatever its label")
    func absentTypeIsFine() throws {
        let kinds = try Self.markers(
            "<Marker><text>Fine</text><label>fine</label></Marker><Marker><label>end</label></Marker>",
        ).map(\.kind)
        #expect(kinds == [.fine, .fine])
    }

    @Test("a file with no version attribute is read as 4.60 or later: a marker without <markerType> is a Fine")
    func noVersionAttribute() throws {
        let kinds = try Self.markers(
            "<Marker><label>segno</label></Marker><Marker><label>coda</label><markerType>coda</markerType></Marker>",
            version: nil,
        ).map(\.kind)
        #expect(kinds == [.fine, .toCoda])
    }

    /// Review Focus 3.
    @Test("before 4.60 the type is read from <label>, SEGNO when there is none", arguments: ["3.01", "4.50"])
    func labelTypesOlderFiles(version: String) throws {
        let xml = """
        <Marker><text><sym>segno</sym></text><label>segno</label></Marker>
        <Marker><text>Fine</text><label>fine</label></Marker>
        <Marker><text><sym>coda</sym></text><label>codab</label></Marker>
        <Marker><text>To Coda</text><label>coda</label></Marker>
        <Marker><text>Solo</text><label>solo</label></Marker>
        <Marker><text><sym>segno</sym></text></Marker>
        """
        let kinds = try Self.markers(xml, version: version).map(\.kind)
        #expect(kinds == [.segno, .fine, .coda, .toCoda, .user, .segno])
    }

    /// Review Focus 3.
    @Test("MuseScore 3's segno in repeat53 is a segno, not a Fine")
    func repeat53Segno() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("repeat53"))
        let measures = score.parts.first?.staves.first?.measures ?? []
        let kinds = measures.flatMap(\.markers).map(\.kind)
        #expect(kinds == [.segno])
    }

    /// Review Focus 2.
    @Test("this library's pre-W3 spellings read back as what they were saved as")
    func legacySpellings() throws {
        let xml = """
        <Marker><markerType>toCoda</markerType><label>coda</label><text>To Coda</text></Marker>
        <Marker><markerType>toCodaSym</markerType><label>coda</label><text></text></Marker>
        <Marker><markerType>daCapo</markerType><label></label><text>D.C.</text></Marker>
        <Marker><markerType>dalSegno</markerType><label></label><text>D.S.</text></Marker>
        <Marker><markerType>coda</markerType><label></label><text></text></Marker>
        <Marker><markerType>coda</markerType><label>codab</label><text></text></Marker>
        <Marker><markerType>coda</markerType><label>coda</label><text>To Coda</text></Marker>
        """
        let kinds = try Self.markers(xml).map(\.kind)
        #expect(kinds == [.toCoda, .toCodaSym, .daCapo, .dalSegno, .coda, .coda, .toCoda])
    }

    /// Before W3 a Coda imported from MusicXML (`<coda/>`, labeled by `<sound coda>`, often `coda`) or from a PDF's
    /// text layer (labeled `coda`, text "Coda") was saved as `<markerType>coda</markerType>` with that label and a
    /// `<text>`, empty or "Coda" — the To Coda's type name and label. MuseScore never writes a To Coda that way: it
    /// gives one words on reading (`Marker::setMarkerType`), and this library now writes a textless To Coda with no
    /// `<text>`.
    @Test("a pre-W3 Coda labeled `coda` is told from a To Coda by its text")
    func legacyCodaLabeledCoda() throws {
        let xml = """
        <Marker><markerType>coda</markerType><label>coda</label><text></text></Marker>
        <Marker><markerType>coda</markerType><label>coda</label><text>Coda</text></Marker>
        <Marker><text>To Coda</text><label>coda</label><markerType>coda</markerType></Marker>
        <Marker><label>coda</label><markerType>coda</markerType></Marker>
        <Marker><text>To Coda</text><label/><markerType>coda</markerType></Marker>
        <Marker><text><sym>coda</sym></text><label>coda</label><markerType>coda</markerType></Marker>
        """
        let kinds = try Self.markers(xml).map(\.kind)
        #expect(kinds == [.coda, .coda, .toCoda, .toCoda, .toCoda, .toCoda])
    }

    /// Review Focus 2.
    @Test("a pre-W3 `other` is recovered from its label, and the four `coda` labels from their text")
    func legacyOther() throws {
        let xml = """
        <Marker><markerType>other</markerType><label>codab</label><text><sym>coda</sym></text></Marker>
        <Marker><markerType>other</markerType><label>fine</label><text>Fine</text></Marker>
        <Marker><markerType>other</markerType><label>segno</label><text><sym>segno</sym></text></Marker>
        <Marker><markerType>other</markerType><label>varcoda</label><text><sym>codaSquare</sym></text></Marker>
        <Marker><markerType>other</markerType><label>coda</label><text>To <sym>coda</sym></text></Marker>
        <Marker><markerType>other</markerType><label>coda</label><text>Da Coda</text></Marker>
        <Marker><markerType>other</markerType><label>coda</label><text>Da Doppia Coda</text></Marker>
        <Marker><markerType>other</markerType><label>coda</label><text>Coda II</text></Marker>
        <Marker><markerType>other</markerType><label>solo</label><text>Solo</text></Marker>
        """
        let kinds = try Self.markers(xml).map(\.kind)
        #expect(kinds == [.coda, .fine, .segno, .varcoda, .toCodaSym, .daCoda, .daDoubleCoda, .user, .user])
    }

    @Test("an empty label still answers to the type's default")
    func emptyLabelTakesDefault() throws {
        let labels = try Self.markers("<Marker><label></label><markerType>dacoda</markerType></Marker>").map(\.label)
        #expect(labels == ["coda"])
    }

    @Test("the marker fixture decodes every MuseScore type; the varcoda without <text> has empty text")
    func fixture() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("markers-jumps"))
        let measures = try #require(score.parts.first?.staves.first).measures
        let kinds = measures.map { $0.markers.map(\.kind) }
        #expect(kinds == [
            [.segno], [.varsegno], [.toCoda], [.toCodaSym], [.daCoda], [.daDoubleCoda], [], [.coda, .user],
            [.varcoda, .codetta], [.fine],
        ])
        #expect(measures[8].markers.first?.text.isEmpty == true)
        let jumpCounts = measures.map(\.jumps.count)
        #expect(jumpCounts == [0, 0, 0, 0, 0, 0, 1, 0, 0, 1])
    }

    /// The decode fix reaches playback: a Fine is a right marker, ordered after its bar's segno whatever the file's
    /// order (`repeatlist.cpp:590-618`), so a D.S. al Fine back to that bar stops at its end. Read as the `.other` this
    /// library made of it before, the Fine came first, was never met again, and the piece played on.
    @Test("a 4.60 Fine without <markerType> stops a D.S. al Fine in the bar its segno opens")
    func fineStopsDalSegno() throws {
        let bar = try XMLTreeParser.parse(Data("""
        <Measure><Marker><text>Fine</text><label>fine</label></Marker>
        <Marker><text><sym>segno</sym></text><label>segno</label><markerType>segno</markerType></Marker>
        <voice></voice></Measure>
        """.utf8), preservingMixedContentIn: ["text"])
        let decoded = try Measure.decode(bar)
        #expect(decoded.markers.map(\.kind) == [.fine, .segno])
        func measure(markers: [Marker] = [], jumps: [Jump] = []) -> Measure {
            Measure(
                voices: [Voice(elements: [.chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))])],
                markers: markers, jumps: jumps,
            )
        }
        let score = Score(division: 480, parts: [Part(
            id: "P0", instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: [
                measure(),
                measure(markers: decoded.markers),
                measure(jumps: [Jump(jumpTo: "segno", playUntil: "fine", text: "D.S. al Fine")]),
            ])],
        )])
        let plan = RepeatUnwinder.plan(navigation: ScoreNavigation(score: score)).map(\.measureIndex)
        #expect(plan == [0, 1, 2, 1])
    }
}
