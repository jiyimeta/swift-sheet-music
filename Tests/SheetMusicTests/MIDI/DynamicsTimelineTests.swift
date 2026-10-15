@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// A voice's dynamics timeline — its ramps and the levels its dynamics set, by original tick — is what the SMF reads a
/// chord's velocity from; a pass after a jump hears its own levels and carries one in until the first.
@Suite("Dynamics timeline")
struct DynamicsTimelineTests {
    private typealias F = DynamicPlaybackFixtures

    private static func timeline(_ score: Score) -> DynamicsTimeline {
        let part = score.parts[0]
        return HairpinRamps.timeline(
            voiceIndex: 0, staff: part.staves[0], instrument: part.instrument, division: score.division,
            tempoMap: score.resolvedTempoMap(),
        )
    }

    @Test("a voice's levels and ramps, read by tick")
    func levelsAndRamps() {
        let timeline = Self.timeline(F.score([
            [F.dynamic("p"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("f"), F.quarter, F.quarter, F.quarter, F.quarter],
        ]))
        #expect(timeline.levels.map(\.tick) == [0, 1920])
        #expect(timeline.levels.map(\.velocity) == [49, 96])
        #expect(timeline.initialVelocity == 80)
        #expect(timeline.velocity(atOriginalTick: 960) == 73)
        #expect(timeline.velocity(atOriginalTick: 2400) == 96)
    }

    @Test("a pass hears its own levels, and the level it carried in until the first")
    func aPassCarriesItsLevelIn() {
        let timeline = Self.timeline(F.score([
            [F.dynamic("p"), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.quarter, F.quarter, F.dynamic("f"), F.quarter, F.quarter],
        ])).pass(startingAt: 1920, carrying: 33)
        #expect(timeline.velocity(atOriginalTick: 1920) == 33)
        #expect(timeline.velocity(atOriginalTick: 2400) == 33)
        #expect(timeline.velocity(atOriginalTick: 2880) == 96)
        #expect(timeline.carriedVelocity(atOriginalTick: 3839) == 96)
    }

    @Test("a measure repeat replays its source's dynamics — an accent too — at its own ticks")
    func aMeasureRepeatReplaysItsSourcesDynamics() throws {
        let score = F.score([
            [F.dynamic("p"), F.quarter, F.dynamic("sf"), F.quarter, F.quarter, F.quarter],
            [.measureRepeat(MeasureRepeat(numMeasures: 1, duration: .measure))],
        ])
        #expect(try F.velocities(score) == [49, 96, 49, 49, 49, 96, 49, 49])
    }
}
