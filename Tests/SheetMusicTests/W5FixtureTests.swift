import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// The five W5 fixtures parse, and say what the W5 tests below assume of them. Counted on the raw XML for the two
/// element kinds that are still preserved markup until Task 5, on the model for the rest.
@Suite("W5 fixtures")
struct W5FixtureTests {
    private static func occurrences(of tag: String, in name: String) throws -> Int {
        let text = try #require(String(bytes: MSCXFixtureLoader.mscxData(name), encoding: .utf8))
        return text.components(separatedBy: "<\(tag)>").count - 1
    }

    private static func voiceElements(_ score: Score, staff: Int = 0) -> [VoiceElement] {
        score.parts.flatMap(\.staves)[staff].measures.flatMap(\.voices).flatMap(\.elements)
    }

    @Test func annotationTextFixture() throws {
        let score = try AnnotationFixtures.load("w5-annotation-text")
        let elements = Self.voiceElements(score)
        #expect(elements.count { if case .expression = $0 { true } else { false } } == 4)
        #expect(elements.count { if case .sticking = $0 { true } else { false } } == 2)
        #expect(elements.count { if case .dynamic = $0 { true } else { false } } == 2)
    }

    @Test func playTechniquesFixture() throws {
        _ = try AnnotationFixtures.load("w5-play-techniques")
        #expect(try Self.occurrences(of: "PlayTechAnnotation", in: "w5-play-techniques") == 9)
        let score = try AnnotationFixtures.load("w5-play-techniques")
        #expect(score.parts.count == 2)
        #expect(score.parts[0].instrument.channels.map(\.name) == [nil, "pizzicato", "tremolo"])
    }

    @Test func capoFixture() throws {
        let score = try AnnotationFixtures.load("w5-capo-playback")
        let capos = Self.voiceElements(score).compactMap { element -> Capo? in
            if case let .capo(capo) = element { capo } else { nil }
        }
        #expect(capos.map(\.fretPosition) == [3, 2, 5, 4])
        #expect(capos.map(\.isActive) == [true, true, false, true])
        #expect(capos[1].ignoredStrings == [1])
        #expect(capos.map(\.transposeMode) == [nil, nil, nil, .standardOnly])
    }

    @Test func fingeringFixture() throws {
        let score = try AnnotationFixtures.load("w5-fingering-staves")
        #expect(score.parts.count == 1)
        #expect(score.parts[0].staves.count == 2)
        let fingerings = score.parts.flatMap(\.staves).flatMap(\.measures).flatMap(\.voices).flatMap(\.elements)
            .compactMap { element -> [String]? in
                guard case let .chord(chord) = element else { return nil }
                return chord.notes.values.flatMap(\.fingerings).map(\.text)
            }.flatMap(\.self)
        #expect(fingerings.sorted() == ["1", "2", "3", "4", "5"])
    }

    @Test func diagramsFixture() throws {
        #expect(try Self.occurrences(of: "HarpPedalDiagram", in: "w5-diagrams") == 2)
        let score = try AnnotationFixtures.load("w5-diagrams")
        let diagrams = Self.voiceElements(score, staff: 1).compactMap { element -> FretDiagram? in
            if case let .fretDiagram(diagram) = element { diagram } else { nil }
        }
        #expect(diagrams.count == 2)
        #expect(diagrams[0].strings.count == 5)
    }
}
