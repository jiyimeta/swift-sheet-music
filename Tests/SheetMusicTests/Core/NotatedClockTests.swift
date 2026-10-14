import Foundation
@testable import SheetMusicAudioCore
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// The notated clock integrates every tempo-map point, so it agrees with what the engine plays: a rit. that steps
/// mid-bar, or a plain tempo marking half way through a bar, moves the following bars' starts exactly as the SMF's
/// tempo metas and `PlaybackTimeline` do. Before, it read the tempo at each downbeat only.
@Suite("Notated clock")
struct NotatedClockTests {
    /// Seconds to `tick` in a track's tempo metas (120 BPM before the first), the last meta at a tick winning.
    private static func smfSeconds(atTick tick: Int, division: Int, events: [TimedMidiEvent]) -> Double {
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

    /// How close the clock must come to the SMF and `PlaybackTimeline`. Both carry a tempo as whole microseconds per
    /// quarter (180 BPM is 333 333 µs, not 333 333.3…), so they drift from the exact clock by up to half a microsecond
    /// a beat — a couple of microseconds over these scores. A clock that read only each downbeat's tempo misses a
    /// rit.'s mid-bar steps by tens of milliseconds, far outside this.
    private static let engineTolerance = 1e-4

    /// Every measure start and the total of the clock against the SMF's, for a score without repeats.
    private static func expectMatchesSMF(_ score: Score) throws {
        let clock = score.notatedClock()
        let midi = try MidiRenderer.render(score: score)
        let events = try #require(midi.tracks.first).events
        let lengths = score.effectiveMeasureDurations().map { $0.ticks(division: score.division) }
        var base = 0
        for (index, length) in lengths.enumerated() {
            let expected = smfSeconds(atTick: base, division: score.division, events: events)
            #expect(abs(clock.startSeconds(ofMeasure: index) - expected) < Self.engineTolerance, "measure \(index)")
            base += length
        }
        let total = smfSeconds(atTick: base, division: score.division, events: events)
        #expect(abs(clock.durationSeconds - total) < Self.engineTolerance)
        #expect(abs(score.notatedDurationSeconds - total) < Self.engineTolerance)
    }

    @Test("a rit. spanning bars: the notated starts and total equal the SMF's, on MuseScore's own fixtures")
    func rampFixturesMatchTheSMF() throws {
        for fixture in ["tempo-gradual", "gradual_tempo_change_rallentando", "gradual_tempo_change_accelerando"] {
            try Self.expectMatchesSMF(MSCXParser.parse(MSCXFixtureLoader.mscxData(fixture)))
        }
    }

    @Test("a rit. over two bars in a synthetic score matches the SMF and PlaybackTimeline")
    func syntheticRampMatchesTheEngine() throws {
        let score = TempoMapFixtures.score(
            measures: 4,
            lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2))],
            notes: true,
            ramps: [(measure: 1, spanner: TempoMapFixtures.ritardando(measures: 2))],
        )
        try Self.expectMatchesSMF(score)
        let timeline = PlaybackTimeline(score: score)
        #expect(abs(score.notatedClock().durationSeconds - timeline.totalSeconds) < Self.engineTolerance)
        // The ramp steps mid-bar, so a downbeat-only clock would have missed it.
        #expect(score.resolvedTempoMap().points(inMeasure: 1).contains { $0.tickInMeasure > 0 })
    }

    @Test("a plain tempo marking half way through a bar splits that bar's time")
    func midBarTempoChange() throws {
        // Bar 1: 960 ticks at 120 BPM (1 s), then 960 at 180 BPM (2/3 s); bar 2 plays at 180 BPM (4/3 s).
        let score = TempoMapFixtures.score(
            measures: 2,
            lane: [
                TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2)),
                TempoMapFixtures.tempo(0, 2, Tempo(beatsPerSecond: 3)),
            ],
            notes: true,
        )
        let clock = score.notatedClock()
        #expect(abs(clock.startSeconds(ofMeasure: 1) - (1 + 2.0 / 3)) < 1e-9)
        #expect(abs(clock.durationSeconds - 3) < 1e-9)
        #expect(abs(clock.seconds(measureIndex: 0, tickInMeasure: 480) - 0.5) < 1e-9)
        #expect(abs(clock.seconds(measureIndex: 0, tickInMeasure: 1440) - (1 + 1.0 / 3)) < 1e-9)
        try Self.expectMatchesSMF(score)
        #expect(abs(PlaybackTimeline(score: score).totalSeconds - 3) < Self.engineTolerance)
    }

    @Test("cursor(atSeconds:) inverts seconds across ramp steps")
    func cursorInvertsSeconds() {
        let score = TempoMapFixtures.score(
            measures: 4,
            lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2))],
            notes: true,
            ramps: [(measure: 1, spanner: TempoMapFixtures.ritardando(measures: 2))],
        )
        let clock = score.notatedClock()
        for measure in 0 ..< 4 {
            for tick in [0, 240, 960, 1700] {
                let seconds = clock.seconds(measureIndex: measure, tickInMeasure: tick)
                #expect(clock.cursor(atSeconds: seconds) == .beat(measureIndex: measure, tickInMeasure: tick))
            }
        }
        #expect(clock.cursor(atSeconds: -1) == .beat(measureIndex: 0, tickInMeasure: 0))
        #expect(clock.cursor(atSeconds: 1e6) == .beat(measureIndex: 3, tickInMeasure: 1920))
    }

    @Test("a clock built from a given tempo map equals one that resolves its own")
    func suppliedMapEqualsResolvedMap() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("tempo-gradual"))
        let own = score.notatedClock()
        let supplied = score.notatedClock(tempoMap: score.resolvedTempoMap())
        #expect(own.durationSeconds == supplied.durationSeconds)
        #expect(score.cursor(atSeconds: 7.3, clock: supplied) == score.cursor(atSeconds: 7.3))
    }

    @Test("two points on one tick: the last wins, as the tempo map's own lookup has it")
    func sameTickLastPointWins() {
        let score = TempoMapFixtures.score(measures: 2, notes: true)
        let map = ResolvedTempoMap(points: [
            ResolvedTempoMap.Point(measureIndex: 0, tickInMeasure: 0, beatsPerSecond: 2, role: .marking),
            ResolvedTempoMap.Point(measureIndex: 0, tickInMeasure: 960, beatsPerSecond: 3, role: .marking),
            ResolvedTempoMap.Point(measureIndex: 0, tickInMeasure: 960, beatsPerSecond: 4, role: .ramp),
        ])
        #expect(map.beatsPerSecond(atMeasure: 0, tickInMeasure: 960) == 4)
        let clock = score.notatedClock(tempoMap: map)
        // Bar 1: 960 ticks at 2 beats/s (1 s) then 960 at 4 beats/s (0.5 s); bar 2 at 4 beats/s (1 s).
        #expect(abs(clock.startSeconds(ofMeasure: 1) - 1.5) < 1e-9)
        #expect(abs(clock.durationSeconds - 2.5) < 1e-9)
        #expect(abs(clock.seconds(measureIndex: 0, tickInMeasure: 1440) - 1.25) < 1e-9)
    }

    @Test("a score without gradual changes resolves the same tempo map as before")
    func noRampScoreHasNoRampPoints() {
        let score = TempoMapFixtures.score(
            measures: 3, lane: [TempoMapFixtures.tempo(1, 2, Tempo(beatsPerSecond: 3))], notes: true,
        )
        #expect(score.resolvedTempoMap().points.filter { $0.role == .ramp }.isEmpty)
    }
}
