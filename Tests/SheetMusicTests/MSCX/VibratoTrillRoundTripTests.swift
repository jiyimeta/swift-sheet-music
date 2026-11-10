import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// `<Vibrato>` and `<Trill>` payloads: the subtype (the line's type) and the children nothing models must survive a
/// save. Before this, `Spanner.payloadElement` had no branch for either, so every vibrato came back `guitarVibrato`.
@Suite("Vibrato and trill MSCX round-trip")
struct VibratoTrillRoundTripTests {
    /// One bar of two quarters; the line starts on the first and ends on the second, written as MuseScore's pair.
    static func mscx(spanner: String, payload: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <Spanner type="\(spanner)">
                    \(payload)
                    <next><location><fractions>1/4</fractions></location></next>
                  </Spanner>
                  <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
                  <Spanner type="\(spanner)">
                    <prev><location><fractions>-1/4</fractions></location></prev>
                  </Spanner>
                  <Chord><durationType>quarter</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
    }

    static func beginSpanner(_ score: Score, kind: Spanner.Kind) throws -> Spanner {
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        for case let .spanner(spanner) in voice.elements where spanner.kind == kind && !spanner.isEndMarker {
            return spanner
        }
        throw TestFailure.noSpanner
    }

    enum TestFailure: Error { case noSpanner }

    /// Encode `score` and return the text and the re-parsed score.
    static func save(_ score: Score) throws -> (xml: String, reparsed: Score) {
        let xml = try #require(String(data: MSCXEncoder.encode(score), encoding: .utf8))
        return try (xml, MSCXParser.parse(Data(xml.utf8)))
    }

    @Test(arguments: VibratoType.allCases)
    func vibratoTypeSurvivesEncodeDecode(type: VibratoType) throws {
        let score = try MSCXParser.parse(Data(Self.mscx(
            spanner: "Vibrato",
            payload: "<Vibrato><subtype>\(type.rawValue)</subtype></Vibrato>",
        ).utf8))
        #expect(try Self.beginSpanner(score, kind: .vibrato).vibrato?.type == type)

        let (xml, reparsed) = try Self.save(score)
        #expect(xml.contains("<subtype>\(type.rawValue)</subtype>"))
        #expect(try Self.beginSpanner(reparsed, kind: .vibrato).vibrato?.type == type)
    }

    @Test(arguments: TrillType.allCases)
    func trillTypeSurvivesEncodeDecode(type: TrillType) throws {
        let score = try MSCXParser.parse(Data(Self.mscx(
            spanner: "Trill",
            payload: "<Trill><subtype>\(type.rawValue)</subtype></Trill>",
        ).utf8))
        #expect(try Self.beginSpanner(score, kind: .trill).trill?.type == type)

        let (xml, reparsed) = try Self.save(score)
        #expect(xml.contains("<subtype>\(type.rawValue)</subtype>"))
        #expect(try Self.beginSpanner(reparsed, kind: .trill).trill?.type == type)
    }

    @Test
    func unknownVibratoChildSurvives() throws {
        let score = try MSCXParser.parse(Data(Self.mscx(
            spanner: "Vibrato",
            payload: "<Vibrato><subtype>vibratoSawtooth</subtype><foo>1</foo></Vibrato>",
        ).utf8))
        let (xml, reparsed) = try Self.save(score)
        #expect(xml.contains("<foo>1</foo>"))
        let vibrato = try Self.beginSpanner(reparsed, kind: .vibrato)
        #expect(vibrato.vibrato?.type == .sawtooth)
        #expect(!vibrato.payloadMarkup.isEmpty)
    }

    @Test
    func unknownTrillChildSurvives() throws {
        let score = try MSCXParser.parse(Data(Self.mscx(
            spanner: "Trill",
            payload: "<Trill><subtype>upprall</subtype><foo>1</foo></Trill>",
        ).utf8))
        let (xml, _) = try Self.save(score)
        #expect(xml.contains("<foo>1</foo>"))
    }
}
