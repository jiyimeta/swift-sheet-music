import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

@Suite("MusicXML wedges")
struct MusicXMLWedgeTests {
    private typealias F = DirectionFixtures

    private static func wedge(_ type: String, number: Int = 1, extra: String = "") -> String {
        F.direction("<wedge type=\"\(type)\" number=\"\(number)\"/>", extra)
    }

    private static func begins(_ voice: Voice) -> [(tick: Int, spanner: Spanner)] {
        F.spanners(in: voice).filter { !$0.spanner.isEndMarker }
    }

    private static func ends(_ voice: Voice) -> [(tick: Int, spanner: Spanner)] {
        F.spanners(in: voice).filter(\.spanner.isEndMarker)
    }

    @Test("a crescendo spans bars: a begin side with <next> and an end marker in the other bar")
    func crescendoSpansBars() throws {
        let score = try F.score(measures: [
            Self.wedge("crescendo") + F.fourQuarters, Self.wedge("stop") + F.fourQuarters,
        ])
        let begin = try #require(Self.begins(F.voice(score, measure: 0)).first)
        #expect(begin.tick == 0)
        #expect(begin.spanner.kind == .hairpin)
        #expect(begin.spanner.rawType == "HairPin")
        #expect(begin.spanner.hairpin?.subtype == .crescendo)
        #expect(begin.spanner.nextMeasuresOffset == 1)
        #expect(begin.spanner.nextFractionsOffset == nil)
        #expect(begin.spanner.placement == nil)
        #expect(Self.ends(F.voice(score, measure: 1)).map(\.tick) == [0])
    }

    @Test("a diminuendo is the decrescendo subtype")
    func diminuendo() throws {
        let score = try F.score(measures: [Self.wedge("diminuendo") + F.fourQuarters + Self.wedge("stop")])
        let begin = try #require(Self.begins(F.voice(score)).first)
        #expect(begin.spanner.hairpin?.subtype == .decrescendo)
    }

    @Test("a stop inside a chord, a dynamic and a start at the next beat keep every chord in place (testWedgeOffset)")
    func wedgeStopInsideAChord() throws {
        let body = Self.wedge("crescendo") + F.quarter("C") + F.quarter("D")
            + F.direction("<dynamics><f/></dynamics>") + Self.wedge("stop", extra: "<offset>240</offset>")
            + F.quarter("E") + Self.wedge("diminuendo", number: 2) + F.quarter("F")
        let score = try F.score(measures: [body, Self.wedge("stop", number: 2) + F.fourQuarters])
        let voice = F.voice(score)
        #expect(F.chordTicks(in: voice) == [0, 480, 960, 1440])
        #expect(F.dynamics(in: voice).map(\.tick) == [960])
        #expect(F.spanners(in: voice).map(\.tick) == [0, 1200, 1440])
        #expect(F.jogCount(in: voice) == 2)
        let first = try #require(Self.begins(voice).first)
        #expect(first.spanner.nextFractionsOffset == Fraction(numerator: 5, denominator: 8))
    }

    @Test("a wedge with no stop is dropped")
    func unterminated() throws {
        let score = try F.score(measures: [Self.wedge("crescendo") + F.fourQuarters])
        #expect(F.spanners(in: F.voice(score)).isEmpty)
    }

    @Test("wedges with different numbers pair by number")
    func numberedWedges() throws {
        let body = Self.wedge("crescendo", number: 1) + F.quarter("C") + Self.wedge("diminuendo", number: 2)
            + F.quarter("D") + F.quarter("E") + Self.wedge("stop", number: 1) + F.quarter("F")
        let score = try F.score(measures: [body, Self.wedge("stop", number: 2) + F.fourQuarters])
        let begins = Self.begins(F.voice(score))
        #expect(begins.map(\.tick) == [0, 480])
        #expect(begins.map(\.spanner.nextMeasuresOffset) == [0, 1])
        #expect(begins.map(\.spanner.nextFractionsOffset)
            == [Fraction(numerator: 3, denominator: 4), Fraction(numerator: -1, denominator: 4)])
    }

    @Test("a start on the bar line belongs to the next bar")
    func startAtTheBarEnd() throws {
        let score = try F.score(measures: [
            F.fourQuarters + Self.wedge("crescendo"),
            F.quarter("C") + F.quarter("D") + Self.wedge("stop") + F.quarter("E") + F.quarter("F"),
        ])
        #expect(F.spanners(in: F.voice(score, measure: 0)).isEmpty)
        #expect(F.spanners(in: F.voice(score, measure: 1)).map(\.tick) == [0, 960])
    }

    /// The `<direction>` MuseScore stores a hairpin's side in (`setSLinePlacement`, `P2:1641-1652`): `placement`,
    /// else `default-y`'s side (`P2:3372-3379`), else above on a vocal staff and below on any other (`P2:3818-3824`).
    private static func side(
        _ attributes: String = "", wedgeAttributes: String = "", partName: String? = nil,
    ) throws -> [PreservedXML] {
        let start = F.direction("<wedge type=\"crescendo\" number=\"1\"\(wedgeAttributes)/>", attributes: attributes)
        let body = start + F.quarter("C") + F.quarter("D") + Self.wedge("stop") + F.quarter("E") + F.quarter("F")
        let score = try F.score(measures: [body], partName: partName)
        return try #require(Self.begins(F.voice(score)).first).spanner.payloadMarkup
    }

    private static func direction(_ text: String) -> [PreservedXML] {
        [PreservedXML(name: "direction", text: text)]
    }

    @Test("a wedge's side is its <direction>: the placement attribute first")
    func sideFromPlacement() throws {
        #expect(try Self.side("placement=\"below\"") == Self.direction("down"))
        #expect(try Self.side("placement=\"above\"") == Self.direction("up"))
        #expect(try Self.side("placement=\"below\"", partName: "Soprano") == Self.direction("down"))
    }

    @Test("without placement, default-y's sign decides the wedge's side")
    func sideFromDefaultY() throws {
        #expect(try Self.side(wedgeAttributes: " default-y=\"20\"") == Self.direction("up"))
        #expect(try Self.side(wedgeAttributes: " default-y=\"-80\"") == Self.direction("down"))
    }

    @Test("with neither, a wedge is above on a vocal staff and below on any other")
    func sideFromStaff() throws {
        #expect(try Self.side() == Self.direction("down"))
        #expect(try Self.side(partName: "Soprano") == Self.direction("up"))
        #expect(try Self.side(partName: "Voice") == Self.direction("up"))
        #expect(try Self.side(partName: "Soprano Sax") == Self.direction("down"))
    }
}
