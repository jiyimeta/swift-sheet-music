import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// A direction lands on the staff it names, at the tick the clock and its `<offset>` say, with the chords unmoved.
@Suite("MusicXML direction placement")
struct MusicXMLDirectionPlacementTests {
    private typealias F = DirectionFixtures

    private static func dynamicsDirection(_ name: String, extra: String = "") -> String {
        F.direction("<dynamics><\(name)/></dynamics>", extra)
    }

    @Test("a dynamic at the downbeat sits at tick 0 with MuseScore's velocity")
    func dynamicAtDownbeat() throws {
        let score = try F.score(measures: [Self.dynamicsDirection("f") + F.fourQuarters])
        let voice = F.voice(score)
        let found = F.dynamics(in: voice)
        #expect(found.count == 1)
        #expect(found.first?.tick == 0)
        #expect(found.first?.dynamic.subtype == "f")
        #expect(found.first?.dynamic.velocity == Dynamic.defaultVelocity(for: "f"))
        #expect(F.jogCount(in: voice) == 0)
    }

    @Test("a dynamic after two quarters follows the clock")
    func dynamicMidMeasure() throws {
        let body = F.quarter("C") + F.quarter("D") + Self.dynamicsDirection("mp") + F.quarter("E") + F.quarter("F")
        let voice = try F.voice(F.score(measures: [body]))
        #expect(F.dynamics(in: voice).map(\.tick) == [960])
        #expect(F.chordTicks(in: voice) == [0, 480, 960, 1440])
    }

    @Test("an offset moves the dynamic and leaves every chord where it was")
    func offsetMovesIt() throws {
        let body = F.quarter("C") + Self.dynamicsDirection("p", extra: "<offset>240</offset>")
            + F.quarter("D") + F.quarter("E") + F.quarter("F")
        let voice = try F.voice(F.score(measures: [body]))
        #expect(F.dynamics(in: voice).map(\.tick) == [720])
        #expect(F.chordTicks(in: voice) == [0, 480, 960, 1440])
        #expect(F.jogCount(in: voice) == 2)
    }

    @Test("after a backup the second voice's direction is at the start, in the first voice")
    func backupUsesTheClock() throws {
        let body = F.fourQuarters + "<backup><duration>1920</duration></backup>" + Self.dynamicsDirection("p")
            + ["G", "A", "B", "C"].map { F.quarter($0, voice: 2) }.joined()
        let score = try F.score(measures: [body])
        #expect(F.dynamics(in: F.voice(score, voice: 0)).map(\.tick) == [0])
        #expect(F.dynamics(in: F.voice(score, voice: 1)).isEmpty)
    }

    @Test("<staff> picks the staff")
    func staffRouting() throws {
        let body = Self.dynamicsDirection("p", extra: "<staff>2</staff>")
            + F.fourQuarters + "<backup><duration>1920</duration></backup>"
            + ["C", "D", "E", "F"].map { F.quarter($0, octave: 3, voice: 5, staff: 2) }.joined()
        let score = try F.score(measures: [body], staves: 2)
        #expect(F.dynamics(in: F.voice(score, staff: 0)).isEmpty)
        #expect(F.dynamics(in: F.voice(score, staff: 1)).map(\.tick) == [0])
    }

    @Test("a forward keeps the dynamic with the chord it precedes")
    func forwardKeepsTheChordCompany() throws {
        let body = F.quarter("C") + "<forward><duration>480</duration></forward>"
            + Self.dynamicsDirection("f") + F.quarter("D") + F.half("E")
        let voice = try F.voice(F.score(measures: [body]))
        let dynamicTick = F.dynamics(in: voice).first?.tick
        #expect(dynamicTick == F.chordTicks(in: voice)[1])
        #expect(F.jogCount(in: voice) == 0)
    }
}
