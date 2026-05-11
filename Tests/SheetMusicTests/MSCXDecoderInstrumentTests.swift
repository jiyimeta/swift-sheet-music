import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct MSCXDecoderInstrumentTests {
    @Test func decodeArticulationWithName() throws {
        let xml = "<Articulation name=\"staccato\"><velocity>100</velocity><gateTime>50</gateTime></Articulation>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let art = try InstrumentArticulation.decode(node)
        #expect(art.name == "staccato")
        #expect(art.velocity == 100)
        #expect(art.gateTime == 50)
    }

    @Test func decodeDefaultArticulationHasNoName() throws {
        let xml = "<Articulation><velocity>100</velocity><gateTime>100</gateTime></Articulation>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let art = try InstrumentArticulation.decode(node)
        #expect(art.name == nil)
    }

    @Test func decodeChannel() throws {
        let xml = "<Channel><program value=\"52\"/></Channel>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let ch = try InstrumentChannel.decode(node)
        #expect(ch.program == 52)
    }

    @Test func decodeInstrumentWithChannelAndArticulations() throws {
        let xml = """
        <Instrument id="voice">
          <longName>Voice</longName>
          <shortName>Vo.</shortName>
          <trackName>Voice</trackName>
          <minPitchP>38</minPitchP>
          <maxPitchP>84</maxPitchP>
          <minPitchA>41</minPitchA>
          <maxPitchA>79</maxPitchA>
          <Articulation><velocity>100</velocity><gateTime>100</gateTime></Articulation>
          <Articulation name="staccato"><velocity>100</velocity><gateTime>50</gateTime></Articulation>
          <Channel><program value="52"/></Channel>
        </Instrument>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let instr = try Instrument.decode(node)
        #expect(instr.id == "voice")
        #expect(instr.longName == "Voice")
        #expect(instr.shortName == "Vo.")
        #expect(instr.minPitchPlayable == 38)
        #expect(instr.articulations.count == 2)
        #expect(instr.channel.program == 52)
    }

    @Test func decodeDeclaredStaff() throws {
        // Staff.declared decodes <StaffType> from an in-Part <Staff> node.
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (mscxID, staff) = Staff.declared(node)
        #expect(mscxID == "1")
        #expect(staff.staffType == "stdNormal")
        #expect(staff.group == "pitched")
    }

    @Test func decodeDefaultTransposingClefAlsoSetsDefaultClefType() throws {
        // Contrabass-style declaration: only the per-clef forms, no
        // bare <defaultClef>. We collapse to defaultClefType, preferring
        // the transposing clef (the one MuseScore displays when concert
        // pitch is off — the default). Without this, the layout would
        // fall back to G clef.
        let xml = """
        <Staff id="5">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <defaultConcertClef>F8vb</defaultConcertClef>
          <defaultTransposingClef>F</defaultTransposingClef>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.defaultClefType == "F")
    }

    @Test func decodeDefaultConcertClefAloneFallsThrough() throws {
        // Only concert clef declared; we use it.
        let xml = """
        <Staff id="5">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <defaultConcertClef>F8vb</defaultConcertClef>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.defaultClefType == "F8vb")
    }

    @Test func decodeBareDefaultClefStillWins() throws {
        // When <defaultClef> is present, it wins over the per-clef forms.
        let xml = """
        <Staff id="5">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <defaultClef>F</defaultClef>
          <defaultConcertClef>F8vb</defaultConcertClef>
          <defaultTransposingClef>G</defaultTransposingClef>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, staff) = Staff.declared(node)
        #expect(staff.defaultClefType == "F")
    }

    @Test func decodePart() throws {
        let xml = """
        <Part id="1">
          <Staff id="1">
            <StaffType group="pitched"><name>stdNormal</name></StaffType>
          </Staff>
          <trackName>Voice</trackName>
          <Instrument id="voice">
            <Channel><program value="52"/></Channel>
          </Instrument>
        </Part>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let pairing = try Part.decodePairing(node, fallbackIndex: 1)
        #expect(pairing.partID == "1")
        #expect(pairing.trackName == "Voice")
        #expect(pairing.instrument.id == "voice")
        #expect(pairing.declared.count == 1)
    }
}
