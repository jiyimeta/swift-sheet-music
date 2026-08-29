import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCX drumset round-trip")
struct MSCXDrumsetRoundTripTests {
    private static let museScoreDrum = """
    <Instrument id="drumset">
      <useDrumset>1</useDrumset>
      <Drum pitch="36">
        <head>normal</head>
        <line>7</line>
        <voice>1</voice>
        <name>Bass Drum 1</name>
        <stem>2</stem>
        <shortcut>B</shortcut>
        </Drum>
      <Drum pitch="51">
        <head>diamond</head>
        <line>3</line>
        <voice>0</voice>
        <name>Ride (my chart)</name>
        <stem>1</stem>
        </Drum>
      </Instrument>
    """

    @Test("every <Drum> child is decoded, not just the line")
    func decodesWholeEntry() throws {
        let node = try XMLTreeParser.parse(Data(Self.museScoreDrum.utf8))
        let instrument = try Instrument.decode(node)

        #expect(instrument.useDrumset)
        #expect(instrument.drumset[36]?.line == 7)
        #expect(instrument.drumset[36]?.voiceIndex == 1)
        #expect(instrument.drumset[36]?.stem == 2)
        #expect(instrument.drumset[36]?.shortcut == "B")
        #expect(instrument.drumset[51]?.head == "diamond")
        #expect(instrument.drumset[51]?.name == "Ride (my chart)")
        #expect(instrument.drumLineMap == [36: 7, 51: 3])
    }

    @Test("a <Drum> missing its optional children falls back to GM rather than dropping the pitch")
    func decodesSparseEntry() throws {
        let xml = """
        <Instrument id="drumset"><useDrumset>1</useDrumset>
          <Drum pitch="42"><line>-1</line></Drum>
        </Instrument>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let instrument = try Instrument.decode(node)

        #expect(instrument.drumset[42]?.line == -1)
        #expect(instrument.drumset[42]?.head == "cross")
        #expect(instrument.drumset[42]?.name == "Closed Hi-Hat")
        #expect(instrument.drumset[42]?.shortcut == nil)
    }

    @Test("a <Drum> with no line at all is still skipped")
    func skipsLinelessEntry() throws {
        let xml = """
        <Instrument id="drumset"><useDrumset>1</useDrumset>
          <Drum pitch="42"><head>cross</head></Drum>
        </Instrument>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let instrument = try Instrument.decode(node)

        #expect(instrument.drumset.isEmpty)
    }

    @Test("a MuseScore drumset re-encodes to the bytes it was decoded from")
    func reEncodesFaithfully() throws {
        let node = try XMLTreeParser.parse(Data(Self.museScoreDrum.utf8))
        let instrument = try Instrument.decode(node)
        let encoded = instrument.encode()

        let drums = encoded.all("Drum")
        #expect(drums.count == 2)
        let bass = try #require(drums.first { $0.attributes["pitch"] == "36" })
        #expect(bass.children.map(\.name) == ["head", "line", "voice", "name", "stem", "shortcut"])
        #expect(bass.first("head")?.text == "normal")
        #expect(bass.first("line")?.text == "7")
        #expect(bass.first("voice")?.text == "1")
        #expect(bass.first("name")?.text == "Bass Drum 1")
        #expect(bass.first("stem")?.text == "2")
        #expect(bass.first("shortcut")?.text == "B")

        let ride = try #require(drums.first { $0.attributes["pitch"] == "51" })
        #expect(ride.children.map(\.name) == ["head", "line", "voice", "name", "stem"])
        #expect(ride.first("head")?.text == "diamond")
        #expect(ride.first("name")?.text == "Ride (my chart)")
    }

    /// The §6a gate: a kit this package AUTHORS — `Score.blank`'s drum part, whose entries come entirely from
    /// `GMDrumset` — must still encode to the exact bytes it did before the drumset was a real type. The golden
    /// was recorded from the pre-change encoder; a diff here means a GM default moved.
    @Test("an authored drum part encodes byte-identically to the recorded golden")
    func authoredKitIsByteIdentical() throws {
        let template = BlankScoreTemplate(
            title: "Drums",
            parts: [.init(
                instrumentID: "drumset", longName: "Drum Kit",
                staves: [.init(clefType: "PERC", isPercussion: true)],
                isDrums: true,
            )],
            measureCount: 1,
        )
        let score = Score.blank(template)
        let encoded = XMLTreeSerializer.serialize(score.parts[0].instrument.encode())

        let goldenURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/drumsetEncodeGolden.xml")
        let golden = try Data(contentsOf: goldenURL)

        #expect(encoded == golden)
    }
}
