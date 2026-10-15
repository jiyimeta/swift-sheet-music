import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `<PlayTechAnnotation>` and `<HarpPedalDiagram>` decode into annotated staff texts and encode back as MuseScore
/// writes them (default-valued properties omitted).
@Suite("Staff text annotation MSCX")
struct StaffTextAnnotationRoundTripTests {
    private static func lane(_ score: Score, part: Int = 0) -> [(measure: Int, text: StaffText)] {
        score.systemMeasures.enumerated().flatMap { index, measure in
            measure.elements.compactMap { positioned -> (Int, StaffText)? in
                guard case let .staffText(text) = positioned.element,
                      (positioned.originalStaff?.partIndex ?? 0) == part else { return nil }
                return (index, text)
            }
        }
    }

    private static func encoded(_ score: Score, version: MSCXVersion = .v4) throws -> String {
        let data = try MSCXEncoder.encode(score, options: MSCXEncoderOptions(targetVersion: version))
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test("the violin's annotations decode in bar order with their play flags")
    func playTechniquesDecode() throws {
        let score = try AnnotationFixtures.load("w5-play-techniques")
        let violin = Self.lane(score, part: 0)
        #expect(violin.map(\.measure) == [1, 2, 3, 4, 5])
        #expect(violin.map(\.text.text) == ["pizz.", "arco", "trem.", "pizz.", "arco"])
        let annotations = violin.compactMap(\.text.annotation)
        #expect(annotations == [
            .playTechnique(.pizzicato, playsBack: true), .playTechnique(.natural, playsBack: true),
            .playTechnique(.tremolo, playsBack: true), .playTechnique(.pizzicato, playsBack: false),
            .playTechnique(.natural, playsBack: true),
        ])
        let guitar = Self.lane(score, part: 1).compactMap(\.text.annotation)
        #expect(guitar == [
            .playTechnique(.mute, playsBack: true), .playTechnique(.natural, playsBack: true),
            .playTechnique(.harmonics, playsBack: true), .playTechnique(.open, playsBack: true),
        ])
    }

    @Test("they are no longer preserved markup")
    func notPreserved() throws {
        let score = try AnnotationFixtures.load("w5-play-techniques")
        let preserved = score.parts.flatMap(\.staves).flatMap(\.measures).flatMap(\.voices).flatMap(\.elements)
            .filter { if case .preserved = $0 { true } else { false } }
        #expect(preserved.isEmpty)
    }

    @Test("encoding writes MuseScore's shape: type and play only when not default, the text after")
    func playTechniqueEncodes() throws {
        let xml = try Self.encoded(AnnotationFixtures.load("w5-play-techniques"))
        #expect(xml.contains("<PlayTechAnnotation>"))
        #expect(xml.contains("<playTechType>pizzicato</playTechType>"))
        #expect(xml.contains("<play>0</play>"))
        // Natural is the default type: never written.
        #expect(!xml.contains("<playTechType>natural</playTechType>"))
        // And the type precedes the text.
        let type = try #require(xml.range(of: "<playTechType>pizzicato</playTechType>"))
        let text = try #require(xml.range(of: "<text>pizz.</text>", range: type.upperBound ..< xml.endIndex))
        #expect(type.lowerBound < text.lowerBound)
    }

    @Test("encode → decode → encode is a fixed point, and a MuseScore 3 target keeps the text as a staff text")
    func roundTrips() throws {
        let score = try AnnotationFixtures.load("w5-play-techniques")
        let first = try MSCXEncoder.encode(score)
        let again = try MSCXParser.parse(first)
        let before = Self.lane(score, part: 0).compactMap(\.text.annotation)
        #expect(Self.lane(again, part: 0).compactMap(\.text.annotation) == before)
        #expect(try MSCXEncoder.encode(again) == first)
        let v3 = try Self.encoded(score, version: .v3)
        #expect(!v3.contains("<PlayTechAnnotation>"))
        #expect(v3.contains("<text>pizz.</text>"))
    }

    @Test("harp pedal diagrams keep their state, their mode and their glyph markup")
    func harpDecodesAndEncodes() throws {
        let score = try AnnotationFixtures.load("w5-diagrams")
        let harp = Self.lane(score, part: 0)
        #expect(harp.map(\.measure) == [0, 1])
        guard case let .harpPedal(diagram)? = harp.first?.text.annotation,
              case let .harpPedal(text)? = harp.last?.text.annotation
        else {
            Issue.record("harp diagrams did not decode")
            return
        }
        #expect(diagram.isDiagram)
        #expect(diagram.pedals == [.natural, .natural, .flat, .natural, .sharp, .natural, .natural])
        #expect(!text.isDiagram)
        #expect(harp.first?.text.richText?.lines.first?.count == 8)
        let xml = try Self.encoded(score)
        #expect(xml.contains("<HarpPedalDiagram>"))
        #expect(xml.contains("<isDiagram>0</isDiagram>"))
        // A diagram in glyph mode is the default: `<isDiagram>` is written for the text mode only.
        #expect(xml.components(separatedBy: "<isDiagram>").count == 2)
        #expect(xml.components(separatedBy: "<string name=").count == 15)
        #expect(xml.contains("<sym>harpPedalLowered</sym>"))
        #expect(try MSCXEncoder.encode(MSCXParser.parse(MSCXEncoder.encode(score))) == MSCXEncoder.encode(score))
    }

    @Test("a MuseScore 3 staff text MuseScore 4 turns into a technique becomes one here")
    func legacyStaffTextConverts() throws {
        func score(_ version: String, text: String, channel: String? = nil) throws -> Score {
            let switchTag = channel.map { "<channelSwitch voice=\"0\" name=\"\($0)\"/>" } ?? ""
            return try MSCXParser.parse(Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="\(version)"><Score><Division>480</Division>
            <Part><Staff id="1"/><Instrument id="violin"><trackName>Violin</trackName><Channel/></Instrument></Part>
            <Staff id="1"><Measure><voice>
            <StaffText>\(switchTag)<text>\(text)</text></StaffText>
            <Chord><durationType>whole</durationType><Note><pitch>69</pitch><tpc>17</tpc></Note></Chord>
            </voice></Measure></Staff></Score></museScore>
            """.utf8))
        }
        let byText = try Self.lane(score("3.01", text: "Pizzicato")).first?.text.annotation
        #expect(byText == .playTechnique(.pizzicato, playsBack: true))
        let byChannel = try Self.lane(score("3.01", text: "pizz.", channel: "tremolo")).first?.text.annotation
        #expect(byChannel == .playTechnique(.tremolo, playsBack: true))
        let unrelated = try Self.lane(score("3.01", text: "dolce")).first?.text.annotation
        #expect(unrelated == nil)
        // A file MuseScore 4 wrote already says what it means.
        let modern = try Self.lane(score("4.60", text: "pizzicato")).first?.text.annotation
        #expect(modern == nil)
    }
}
