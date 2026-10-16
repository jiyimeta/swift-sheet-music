import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

@Suite("MusicXML lines")
struct MusicXMLLineTests {
    private typealias F = DirectionFixtures

    private static func bracket(_ type: String, attributes: String = "") -> String {
        F.direction("<bracket type=\"\(type)\" number=\"1\" \(attributes)/>")
    }

    private static func begin(_ voice: Voice) -> Spanner? {
        F.spanners(in: voice).first { !$0.spanner.isEndMarker }?.spanner
    }

    private static let hookRows: [(String, Spanner.LineHookType?)] = [
        ("up", .hook90), ("down", .hook90), ("both", .hook90T), ("arrow", .arrowFilled), ("none", nil),
    ]

    @Test("line-end is the begin hook; none is the default and stores nothing", arguments: hookRows)
    func hooks(lineEnd: String, expected: Spanner.LineHookType?) throws {
        let body = Self.bracket("start", attributes: "line-end=\"\(lineEnd)\"") + F.half("C")
            + Self.bracket("stop") + F.half("D")
        let spanner = try #require(try Self.begin(F.voice(F.score(measures: [body]))))
        #expect(spanner.kind == .textLine)
        #expect(spanner.rawType == "TextLine")
        #expect(spanner.lineProperties?.beginHook == expected)
        #expect(spanner.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
    }

    private static let lineTypeRows: [(String, Spanner.LineType?)] = [
        ("dashed", .dashed), ("dotted", .dotted), ("solid", nil),
    ]

    @Test("an explicit line-type that is not the style's solid is kept", arguments: lineTypeRows)
    func lineTypes(lineType: String, expected: Spanner.LineType?) throws {
        let body = Self.bracket("start", attributes: "line-type=\"\(lineType)\"") + F.half("C")
            + Self.bracket("stop") + F.half("D")
        let spanner = try #require(try Self.begin(F.voice(F.score(measures: [body]))))
        #expect(spanner.lineProperties?.lineType == expected)
    }

    @Test("a wavy bracket is a trill line")
    func wavy() throws {
        let body = Self.bracket("start", attributes: "line-type=\"wavy\"") + F.half("C")
            + Self.bracket("stop") + F.half("D")
        let spanner = try #require(try Self.begin(F.voice(F.score(measures: [body]))))
        #expect(spanner.kind == .trill)
        #expect(spanner.trill?.type == .prallprall)
    }

    /// `dashes` sets the line style without unstyling it (`P2:5251-5253`), so MuseScore writes an empty `<TextLine>`
    /// payload, which this model stores as `nil` (`Spanner.lineProperties`).
    @Test("words before dashes are the line's text, not a staff text")
    func dashesWithWords() throws {
        let types = F.words("text") + "</direction-type><direction-type><dashes type=\"start\" number=\"1\"/>"
        let body = F.direction(types) + F.half("C")
            + F.direction("<dashes type=\"stop\" number=\"1\"/>") + F.half("D")
        let score = try F.score(measures: [body])
        let spanner = try #require(Self.begin(F.voice(score)))
        #expect(spanner.kind == .textLine)
        #expect(spanner.beginText == "text")
        #expect(spanner.lineProperties == nil)
        #expect(F.lane(score).isEmpty)
    }

    @Test("dashes whose words are a tempo change are a gradual tempo change")
    func dashesTempoWords() throws {
        let types = F.words("rit.") + "</direction-type><direction-type><dashes type=\"start\" number=\"1\"/>"
        let body = F.direction(types) + F.fourQuarters
        let score = try F.score(measures: [body, F.direction("<dashes type=\"stop\" number=\"1\"/>") + F.fourQuarters])
        let spanner = try #require(Self.begin(F.voice(score)))
        #expect(spanner.kind == .gradualTempoChange)
        #expect(spanner.gradualTempoChange?.type == .ritardando)
        #expect(spanner.beginText == "rit.")
        #expect(spanner.nextMeasuresOffset == 1)
    }

    @Test("a bracket with no stop is dropped")
    func unterminated() throws {
        let body = Self.bracket("start") + F.fourQuarters
        #expect(try F.spanners(in: F.voice(F.score(measures: [body]))).isEmpty)
    }
}
