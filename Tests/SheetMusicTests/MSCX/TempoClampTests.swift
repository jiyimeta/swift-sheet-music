import Foundation
@testable import SheetMusicAudioCore
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A tempo of 0 (or below), and a gradual change with a factor of 0, never reach an integer division or an `Int`
/// conversion of a non-finite number. MuseScore clamps a read `<tempo>` to 5...999 BPM (`TempoText::setTempo`,
/// `dom/tempotext.cpp:324-330`); a zero factor it applies as is, so here it reads as a small positive minimum.
@Suite("Tempo clamps")
struct TempoClampTests {
    private static func decoded(_ tempoText: String) throws -> Tempo {
        let node = try XMLTreeParser.parse(Data("<Tempo><tempo>\(tempoText)</tempo><text>Allegro</text></Tempo>".utf8))
        return try Tempo.decode(node)
    }

    @Test("a <tempo> outside MuseScore's 5...999 BPM reads as the nearest bound", arguments: [
        ("0", 5.0 / 60), ("-3", 5.0 / 60), ("0.01", 5.0 / 60), ("2", 2.0), ("100", 999.0 / 60),
        ("inf", 2.0), ("nan", 2.0),
    ])
    func decodeClampsTheTempo(text: String, expected: Double) throws {
        let tempo = try Self.decoded(text)
        #expect(tempo.beatsPerSecond == expected)
        #expect(tempo.microsecondsPerQuarter > 0)
    }

    @Test("microsecondsPerQuarter survives a tempo built at 0, below 0 and past the bound", arguments: [
        (0.0, 12_000_000), (-1.0, 12_000_000), (Double.nan, 500_000), (Double.infinity, 500_000), (1000.0, 60060),
    ])
    func microsecondsPerQuarterNeverTraps(bps: Double, expected: Int) {
        #expect(Tempo(beatsPerSecond: bps).microsecondsPerQuarter == expected)
    }

    @Test("a stored gradual factor of 0 or below reads as the minimum; the file's value is kept")
    func factorIsClampedOnRead() {
        for factor in [0.0, -2.0] {
            let change = Spanner.GradualTempoChangePayload(type: .ritardando, factor: factor)
            #expect(change.effectiveFactor == Spanner.GradualTempoChangePayload.minimumFactor)
            #expect(change.factor == factor)
        }
        #expect(Spanner.GradualTempoChangePayload(type: .ritardando, factor: .nan).effectiveFactor == 0.75)
        #expect(Spanner.GradualTempoChangePayload(type: .accelerando, factor: 1.5).effectiveFactor == 1.5)
    }

    @Test("a rit. with factor 0 decodes with its text and leaves every tempo-map point positive")
    func zeroFactorRampKeepsTheMapPositive() throws {
        let spanner = try Spanner.decode(XMLTreeParser.parse(Data("""
        <Spanner type="GradualTempoChange"><GradualTempoChange><tempoChangeType>ritardando</tempoChangeType>
        <tempoChangeFactor>0</tempoChangeFactor></GradualTempoChange>
        <next><location><measures>1</measures></location></next></Spanner>
        """.utf8)))
        #expect(spanner.gradualTempoChange?.factor == 0)
        let map = TempoMapFixtures.score(
            measures: 3, lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2))],
            ramps: [(measure: 0, spanner: spanner)],
        ).resolvedTempoMap()
        let slowest = try #require(map.points.map(\.beatsPerSecond).min())
        #expect(slowest > 0)
        #expect(Tempo.microsecondsPerQuarter(beatsPerSecond: slowest) > 0)
    }

    @Test("a count-in tempo under 0.5 BPM or not finite still has a tempo to seed", arguments: [
        (0.0, 60_000_000), (0.3, 60_000_000), (Double.nan, 500_000), (120.0, 500_000), (60.0, 1_000_000),
    ])
    func countInTempoNeverDividesByZero(quarterBpm: Double, expected: Int) {
        let plan = CountInBeats.Result(preRollTicks: 0, beats: [], quarterBpm: quarterBpm)
        #expect(plan.microsecondsPerQuarter == expected)
    }
}
