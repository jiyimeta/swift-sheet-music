import Foundation
@testable import SheetMusicAudioCore
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// Gradual tempo changes in the tempo map as MuseScore builds them (`Score::setUpTempoMap`,
/// `engraving/dom/score.cpp:465-496`): from the tempo in force where the change starts to that times its factor, in
/// `max(8, ticks / division)` eased steps, each written only where no tempo stands yet. MuseScore's own
/// `engraving/tests/tempomap_tests.cpp` expectations run against the same three scores.
@Suite("Gradual tempo ramps")
struct GradualTempoRampTests {
    private static func map(_ fixture: String) throws -> ResolvedTempoMap {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData(fixture)).resolvedTempoMap()
    }

    /// MuseScore's `TempoMap::at(tick)` for a 4/4 score at division 480: the point standing exactly at `tick`.
    private static func point(_ map: ResolvedTempoMap, atTick tick: Int) -> ResolvedTempoMap.Point? {
        map.points.first { $0.measureIndex * 1920 + $0.tickInMeasure == tick }
    }

    /// Seconds to `tick` in a track's tempo metas (120 BPM before the first), the last meta at a tick winning.
    private static func seconds(atTick tick: Int, division: Int, events: [TimedMidiEvent]) -> Double {
        var seconds = 0.0
        var lastTick = 0
        var micros = 500_000
        for event in events where event.tick <= tick {
            guard case let .meta(.tempo(value)) = event.event else { continue }
            seconds += Double(event.tick - lastTick) * Double(micros) / 1_000_000 / Double(division)
            lastTick = event.tick
            micros = value
        }
        return seconds + Double(tick - lastTick) * Double(micros) / 1_000_000 / Double(division)
    }

    @Test("MuseScore's rallentando oracle: 120 at the start, 90 where it ends")
    func rallentandoOracle() throws {
        let map = try Self.map("gradual_tempo_change_rallentando")
        let start = try #require(Self.point(map, atTick: 0))
        let end = try #require(Self.point(map, atTick: 6 * 4 * 480))
        #expect(abs(start.beatsPerSecond - 120.0 / 60) < 1e-6)
        #expect(abs(end.beatsPerSecond - 90.0 / 60) < 1e-6)
    }

    @Test("MuseScore's accelerando oracle: 120 at the start, 159.6 where it ends")
    func accelerandoOracle() throws {
        let map = try Self.map("gradual_tempo_change_accelerando")
        let start = try #require(Self.point(map, atTick: 0))
        let end = try #require(Self.point(map, atTick: 6 * 4 * 480))
        #expect(abs(start.beatsPerSecond - 120.0 / 60) < 1e-6)
        #expect(abs(end.beatsPerSecond - 159.6 / 60) < 1e-6)
    }

    @Test("a ramp never overwrites a tempo text — MuseScore's issue 12140 oracle")
    func doesntOverwriteOtherTempo() throws {
        let map = try Self.map("gradual_tempo_change_doesnt_overwrite_other_tempo")
        let expected: [(tick: Int, bpm: Double)] = [
            (0, 120), (960, 112.5), (1440, 80), (1920, 105), (2880, 97.5), (3840, 187),
        ]
        for (tick, bpm) in expected {
            let found = Self.point(map, atTick: tick)
            let error = found.map { abs($0.beatsPerSecond - bpm / 60) } ?? .infinity
            #expect(error < 1e-6, "tick \(tick)")
        }
        #expect(Self.point(map, atTick: 1440)?.role == .marking)
        #expect(Self.point(map, atTick: 3840)?.role == .marking)
    }

    @Test("an a tempo after a rit. plays the pre-rit tempo, in audio and cursor alike")
    func aTempoAfterRitardando() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("tempo-gradual"))
        let map = score.resolvedTempoMap()
        let aTempo = try #require(map.point(inForceAtMeasure: 2, tickInMeasure: 0))
        #expect(aTempo.beatsPerSecond == 1.333333)
        #expect(aTempo.role == .marking)
        let lastStep = try #require(map.point(inForceAtMeasure: 1, tickInMeasure: 1919))
        #expect(lastStep.role == .ramp)
        #expect(abs(lastStep.beatsPerSecond - 1.041666) < 2e-6)
        let midi = try MidiRenderer.render(score: score)
        let smfSeconds = Self.seconds(atTick: 3840, division: 480, events: midi.tracks[0].events)
        let frame = try #require(PlaybackTimeline(score: score).frames.first { $0.tick == 3840 })
        #expect(abs(frame.timeSeconds - smfSeconds) < 1e-6)
    }

    @Test("ramp points are a separate pass: an a tempo reads the last text marking, not the ramp's last step")
    func aTempoReadsTheTextPassNotTheRamp() throws {
        let eighty = 80.0 / 60
        let score = TempoMapFixtures.score(
            measures: 3,
            lane: [
                TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: eighty)),
                TempoMapFixtures.tempo(2, 0, Tempo(beatsPerSecond: 2, textType: .aTempo)),
            ],
            ramps: [(measure: 1, spanner: TempoMapFixtures.ritardando(measures: 1))],
        )
        let map = score.resolvedTempoMap()
        let ramped = try #require(map.point(inForceAtMeasure: 1, tickInMeasure: 1680))
        #expect(ramped.role == .ramp)
        #expect(ramped.beatsPerSecond < eighty)
        let aTempo = try #require(map.point(inForceAtMeasure: 2, tickInMeasure: 0))
        #expect(aTempo.role == .marking)
        #expect(abs(aTempo.beatsPerSecond - eighty) < 1e-9)
    }

    @Test("a ramp step is written only where no point stands: an explicit marking at a step's tick wins")
    func markingAtAStepTickWins() throws {
        let score = TempoMapFixtures.score(
            measures: 3,
            lane: [
                TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 80.0 / 60)),
                TempoMapFixtures.tempo(1, 2, Tempo(beatsPerSecond: 3)),
            ],
            ramps: [(measure: 1, spanner: TempoMapFixtures.ritardando(measures: 1))],
        )
        let map = score.resolvedTempoMap()
        let atMarking = try #require(map.point(inForceAtMeasure: 1, tickInMeasure: 960))
        #expect(atMarking.role == .marking)
        #expect(atMarking.beatsPerSecond == 3)
        let atStepsBefore = map.points(inMeasure: 1).filter { $0.tickInMeasure == 720 }
        #expect(atStepsBefore.count == 1)
        #expect(atStepsBefore.first?.role == .ramp)
        let atTick960 = map.points(inMeasure: 1).filter { $0.tickInMeasure == 960 }
        #expect(atTick960.count == 1)
    }

    @Test("an eased accelerando rises convexly to its factor; a muted change sets nothing")
    func easedAccelerandoAndMutedChange() throws {
        let map = try Self.map("tempo-gradual")
        let steps = map.points.filter { $0.role == .ramp && ($0.measureIndex == 3 || $0.measureIndex == 4) }
        try #require(steps.count == 9)
        let values = steps.map(\.beatsPerSecond)
        let last = try #require(values.last)
        #expect(values.first == 1.333333)
        #expect(abs(last - 2) < 2e-6)
        let rises = zip(values.dropFirst(), values).map { $0 - $1 }
        let concaveSteps = zip(rises.dropFirst(), rises).filter { $0 < $1 }.count
        #expect(concaveSteps == 0)
        #expect(map.points(inMeasure: 5).isEmpty)
    }

    @Test("a ramp step counts in the beat of the marking in force")
    func rampStepsCarryTheBeatInForce() throws {
        let score = TempoMapFixtures.score(
            measures: 3,
            lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1))],
            ramps: [(measure: 1, spanner: TempoMapFixtures.ritardando(measures: 1))],
        )
        let step = try #require(score.resolvedTempoMap().point(inForceAtMeasure: 1, tickInMeasure: 1000))
        #expect(step.role == .ramp)
        #expect(step.beatDots == 1)
        #expect(step.beatsPerMinute < 80)
    }

    @Test("a score without gradual changes keeps its markings' map exactly")
    func noRampKeepsTheMarkings() {
        let lane = [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 1.5))]
        let score = TempoMapFixtures.score(measures: 2, lane: lane)
        #expect(score.resolvedTempoMap() == ResolvedTempoMap.markings(lane: score.systemMeasures.values, division: 480))
    }
}
