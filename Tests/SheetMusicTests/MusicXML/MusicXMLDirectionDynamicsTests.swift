import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

@Suite("MusicXML direction dynamics")
struct MusicXMLDirectionDynamicsTests {
    private typealias F = DirectionFixtures

    private static func dynamics(_ inner: String, extra: String = "", attributes: String = "") -> String {
        F.direction("<dynamics\(attributes.isEmpty ? "" : " " + attributes)>\(inner)</dynamics>", extra)
    }

    private static func first(_ score: Score) -> Dynamic? {
        F.dynamics(in: F.voice(score)).first?.dynamic
    }

    @Test("other-dynamics keeps its words and plays the token's velocity")
    func otherDynamics() throws {
        let body = Self.dynamics("<other-dynamics>subito p</other-dynamics>") + F.fourQuarters
        let dynamic = try Self.first(F.score(measures: [body]))
        #expect(dynamic?.subtype == "p")
        #expect(dynamic?.velocity == 49)
        #expect(dynamic?.customXMLText == "subito <sym>dynamicPiano</sym>")
    }

    @Test("an unknown other-dynamics word is MuseScore's OTHER, with the word as its text")
    func unknownOtherDynamics() throws {
        let body = Self.dynamics("<other-dynamics>ad lib.</other-dynamics>") + F.fourQuarters
        let dynamic = try Self.first(F.score(measures: [body]))
        #expect(dynamic?.subtype == "other-dynamics")
        #expect(dynamic?.customXMLText == "ad lib.")
    }

    private static let velocities: [(String, Int)] = [
        ("100", 90), ("54.44", 49), ("200", 127), ("0", 96), ("0.4", 96),
    ]

    @Test(
        "<sound dynamics> is a velocity: ×0.9, rounded, clamped to 0…127; a result of 0 means the table's",
        arguments: velocities,
    )
    func soundDynamics(value: String, expected: Int) throws {
        let body = Self.dynamics("<f/>", extra: "<sound dynamics=\"\(value)\"/>") + F.fourQuarters
        #expect(try Self.first(F.score(measures: [body]))?.velocity == expected)
    }

    @Test("two elements in one <dynamics> are two dynamics on one tick, in order")
    func twoInOne() throws {
        let body = Self.dynamics("<f/><p/>") + F.fourQuarters
        let found = try F.dynamics(in: F.voice(F.score(measures: [body])))
        #expect(found.map(\.dynamic.subtype) == ["f", "p"])
        #expect(found.map(\.tick) == [0, 0])
    }

    @Test("words that are a dynamic become one when inferring", arguments: [true, false])
    func wordsThatAreADynamic(infer: Bool) throws {
        let body = F.direction(F.words("mf")) + F.fourQuarters
        let score = try F.score(measures: [body], infer: infer)
        let texts = F.lane(score).filter { entry in
            if case .staffText = entry.element { return true }
            return false
        }
        #expect(F.dynamics(in: F.voice(score)).map(\.dynamic.subtype) == (infer ? ["mf"] : []))
        #expect(texts.count == (infer ? 0 : 1))
    }

    @Test("a lone m, r, s or z stays a word")
    func singleLettersStayWords() throws {
        let body = F.direction(F.words("s")) + F.fourQuarters
        let score = try F.score(measures: [body])
        #expect(F.dynamics(in: F.voice(score)).isEmpty)
    }

    @Test("two dynamics joined by a hyphen are one dynamic with combined text")
    func dynamicRange() throws {
        let types = "<dynamics><mp/></dynamics></direction-type><direction-type><words>-</words></direction-type>"
            + "<direction-type><dynamics><f/></dynamics>"
        let body = F.direction(types) + F.fourQuarters
        let found = try F.dynamics(in: F.voice(F.score(measures: [body])))
        #expect(found.count == 1)
        #expect(found.first?.dynamic.subtype == "mp")
        #expect(found.first?.dynamic.customXMLText == "<sym>dynamicMezzo</sym><sym>dynamicPiano</sym>"
            + "<sym>dynamicCombinedSeparatorHyphen</sym><sym>dynamicForte</sym>")
    }

    @Test("a color attribute reaches the dynamic")
    func color() throws {
        let body = Self.dynamics("<p/>", attributes: "color=\"#0000FF\"") + F.fourQuarters
        let dynamic = try Self.first(F.score(measures: [body]))
        #expect(dynamic?.elementProperties.color == ScoreColor(red: 0, green: 0, blue: 255, alpha: 255))
    }
}
