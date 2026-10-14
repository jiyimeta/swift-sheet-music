import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A dynamic's and a hairpin's `<voiceAssignment>` are read into the model and saved where MuseScore writes them, only
/// when not the whole instrument (`TWrite::writeProperties(const TextBase*)`, `rw/write/twrite.cpp:1320-1325`;
/// `TWrite::write(const Hairpin*)`, `:1683-1697`); an older file's `<dynType>` reads as MuseScore 4 reads it.
@Suite("Voice assignment round trip")
struct VoiceAssignmentRoundTripTests {
    private static func fixture() throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData("dynamics-voices"))
    }

    private static func dynamics(_ score: Score, staff: Int, measure: Int, voice: Int) -> [Dynamic] {
        score.parts[0].staves[staff].measures[measure].voices[voice].elements.values.compactMap { element in
            if case let .dynamic(dynamic) = element { dynamic } else { nil }
        }
    }

    /// Every `<Dynamic>` of a saved file, staff by staff, in document order.
    private static func savedDynamics(_ data: Data) throws -> [XMLTreeNode] {
        let root = try XMLTreeParser.parse(data)
        let staves = try #require(root.first("Score")).all("Staff")
        return staves.flatMap { $0.all("Measure") }.flatMap { $0.all("voice") }.flatMap { $0.all("Dynamic") }
    }

    /// One bar of one staff: `content`, then a whole-note C4.
    private static func oneBar(_ content: String, version: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="\(version)">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  \(content)
                  <Chord><durationType>whole</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
    }

    @Test("the fixture's assignments are read")
    func readsTheAssignments() throws {
        let score = try Self.fixture()
        #expect(Self.dynamics(score, staff: 0, measure: 0, voice: 0).map(\.voiceAssignment) == [.allInInstrument])
        #expect(Self.dynamics(score, staff: 0, measure: 1, voice: 0).map(\.voiceAssignment) == [.allInStaff])
        #expect(Self.dynamics(score, staff: 0, measure: 1, voice: 1).map(\.voiceAssignment) == [.currentVoiceOnly])
        #expect(Self.dynamics(score, staff: 1, measure: 2, voice: 0).map(\.voiceAssignment) == [.currentVoiceOnly])
    }

    @Test("an assignment is saved right after <velocity>, and only when it is not the whole instrument")
    func savesTheAssignments() throws {
        let saved = try Self.savedDynamics(MSCXEncoder.encode(Self.fixture()))
        let assignments = saved.map { $0.first("voiceAssignment")?.text }
        #expect(assignments == [nil, "allInStaff", "currentVoiceOnly", nil, "currentVoiceOnly"])
        let names = try #require(saved.dropFirst().first).children.map(\.name)
        #expect(names.firstIndex(of: "voiceAssignment") == names.firstIndex(of: "velocity").map { $0 + 1 })
    }

    @Test("<dynType> reads as MuseScore 4 reads it; saved as <voiceAssignment>, as <dynType> for 3", arguments: [
        (0, VoiceAssignment.allInStaff), (1, VoiceAssignment.allInInstrument), (2, VoiceAssignment.allInInstrument),
    ] as [(Int, VoiceAssignment)])
    func dynType(value: Int, expected: VoiceAssignment) throws {
        let dynamic = "<Dynamic><subtype>p</subtype><velocity>49</velocity><dynType>\(value)</dynType></Dynamic>"
        let score = try MSCXParser.parse(Data(Self.oneBar(dynamic, version: "3.02").utf8))
        #expect(Self.dynamics(score, staff: 0, measure: 0, voice: 0).map(\.voiceAssignment) == [expected])
        let v4 = try #require(String(bytes: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(!v4.contains("<dynType>"))
        #expect(v4.contains("<voiceAssignment>allInStaff</voiceAssignment>") == (expected == .allInStaff))
        let options = MSCXEncoderOptions(targetVersion: .v3)
        let v3 = try #require(String(bytes: MSCXEncoder.encode(score, options: options), encoding: .utf8))
        #expect(v3.contains("<dynType>0</dynType>") == (expected == .allInStaff))
        #expect(!v3.contains("<voiceAssignment>"))
    }

    @Test("a hairpin's assignment is read, and saved right after its <subtype>")
    func hairpinAssignment() throws {
        let hairpin = """
        <Spanner type="HairPin"><HairPin><subtype>0</subtype>\
        <voiceAssignment>currentVoiceOnly</voiceAssignment></HairPin>\
        <next><location><fractions>1/2</fractions></location></next></Spanner>
        """
        let score = try MSCXParser.parse(Data(Self.oneBar(hairpin, version: "4.60").utf8))
        let payloads = score.parts[0].staves[0].measures[0].voices[0].elements.values.compactMap { element in
            if case let .spanner(spanner) = element { spanner.hairpin } else { nil }
        }
        #expect(payloads.map(\.voiceAssignment) == [.currentVoiceOnly])
        let root = try XMLTreeParser.parse(MSCXEncoder.encode(score))
        let staff = try #require(root.first("Score")?.first("Staff"))
        let saved = staff.all("Measure").flatMap { $0.all("voice") }.flatMap { $0.all("Spanner") }
            .compactMap { $0.first("HairPin") }
        let names = try #require(saved.first).children.map(\.name)
        #expect(names.firstIndex(of: "voiceAssignment") == names.firstIndex(of: "subtype").map { $0 + 1 })
    }
}
