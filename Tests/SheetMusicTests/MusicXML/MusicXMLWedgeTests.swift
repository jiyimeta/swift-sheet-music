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
}
