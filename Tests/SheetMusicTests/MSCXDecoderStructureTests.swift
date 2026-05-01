import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite struct MSCXDecoderStructureTests {
    @Test func decodeVoicePreservesOrder() throws {
        let xml = """
        <voice>
          <KeySig><concertKey>1</concertKey></KeySig>
          <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
          <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
          <Rest><durationType>quarter</durationType></Rest>
        </voice>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let voice = try Voice.decode(node)
        #expect(voice.elements.count == 4)
        guard
            case .keySignature = voice.elements[0],
            case .timeSignature = voice.elements[1],
            case let .chord(c) = voice.elements[2], !c.notes.isEmpty,
            case let .chord(r) = voice.elements[3], r.notes.isEmpty
        else {
            Issue.record("voice element order/types unexpected: \(voice.elements)")
            return
        }
    }

    @Test func decodeVoiceSkipsUnknownChild() throws {
        // The decoder is permissive: unknown elements are silently ignored so that
        // mscx files using features we haven't promoted to first-class still parse.
        let xml = "<voice><Tuplet/><Rest><durationType>quarter</durationType></Rest></voice>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let voice = try Voice.decode(node)
        #expect(voice.elements.count == 1)
        guard case let .chord(r) = voice.elements[0], r.notes.isEmpty else {
            Issue.record("expected the rest to survive, got \(voice.elements)")
            return
        }
    }

    @Test func decodeMeasureWithSingleVoice() throws {
        let xml = """
        <Measure>
          <voice>
            <Rest><durationType>whole</durationType></Rest>
          </voice>
        </Measure>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let measure = try Measure.decode(node)
        #expect(measure.voices.count == 1)
        #expect(measure.voices[0].elements.count == 1)
    }

    @Test func decodeStaffContent() throws {
        let xml = """
        <Staff id="1">
          <Measure>
            <voice>
              <Rest><durationType>whole</durationType></Rest>
            </voice>
          </Measure>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let staff = try StaffContent.decode(node)
        #expect(staff.id == 1)
        #expect(staff.measures.count == 1)
    }
}
