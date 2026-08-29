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
}
