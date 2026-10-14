@testable import SheetMusicCore
import Testing

/// `ResolvedTempoMap`: measure-relative points in score order, the point in force at a position, the beat each one is
/// counted in — and the quarter BPM and the notated clock reading it.
@Suite("Resolved tempo map")
struct ResolvedTempoMapTests {
    private static let threeMarkings = TempoMapFixtures.score(measures: 3, lane: [
        TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2)),
        TempoMapFixtures.tempo(1, 0, Tempo(beatsPerSecond: 1)),
        TempoMapFixtures.tempo(1, 1, Tempo(beatsPerSecond: 1.5)),
    ])

    @Test("a score without markings has no points and plays at 120")
    func noMarkingPlaysTheDefault() {
        let map = TempoMapFixtures.score(measures: 2).resolvedTempoMap()
        #expect(map.points.isEmpty)
        #expect(map.beatsPerSecond(atMeasure: 1, tickInMeasure: 0) == 2)
        #expect(map.point(inForceAtMeasure: 1, tickInMeasure: 0) == nil)
    }

    @Test("points are measure-relative and in score order, whatever the lane order")
    func pointsAreMeasureRelativeInScoreOrder() {
        let map = TempoMapFixtures.score(measures: 2, lane: [
            TempoMapFixtures.tempo(1, 1, Tempo(beatsPerSecond: 1.5)),
            TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2)),
            TempoMapFixtures.tempo(1, 0, Tempo(beatsPerSecond: 1)),
        ]).resolvedTempoMap()
        #expect(map.points.map(\.measureIndex) == [0, 1, 1])
        #expect(map.points.map(\.tickInMeasure) == [0, 0, 480])
        #expect(map.points.map(\.beatsPerSecond) == [2, 1, 1.5])
        #expect(map.points.map(\.role) == [.marking, .marking, .marking])
    }

    @Test("the point in force is the last one at or before the position")
    func inForceIsTheLastPointAtOrBefore() {
        let map = Self.threeMarkings.resolvedTempoMap()
        #expect(map.beatsPerSecond(atMeasure: 0, tickInMeasure: 100) == 2)
        #expect(map.beatsPerSecond(atMeasure: 1, tickInMeasure: 0) == 1)
        #expect(map.beatsPerSecond(atMeasure: 1, tickInMeasure: 479) == 1)
        #expect(map.beatsPerSecond(atMeasure: 1, tickInMeasure: 480) == 1.5)
        #expect(map.beatsPerSecond(atMeasure: 7, tickInMeasure: 0) == 1.5)
    }

    @Test("a measure's points, in order")
    func pointsInOneMeasure() {
        let map = Self.threeMarkings.resolvedTempoMap()
        #expect(map.points(inMeasure: 0).count == 1)
        #expect(map.points(inMeasure: 1).map(\.beatsPerSecond) == [1, 1.5])
        #expect(map.points(inMeasure: 2).isEmpty)
    }

    @Test("a point counts in its beat: BPM, glyph and SMF tempo")
    func pointCountsItsBeat() {
        let dotted = ResolvedTempoMap.Point(
            measureIndex: 0, tickInMeasure: 0, beatsPerSecond: 2, role: .marking, beatNote: .quarter, beatDots: 1,
        )
        #expect(dotted.beatsPerMinute == 80)
        #expect(dotted.beatGlyph == "\u{E1D5}\u{E1E7}")
        #expect(dotted.microsecondsPerQuarter == 500_000)
    }

    @Test("the quarter BPM in force and the notated clock read the map")
    func quarterBpmAndClockReadTheMap() {
        let score = TempoMapFixtures.score(measures: 2, lane: [
            TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2)),
            TempoMapFixtures.tempo(1, 0, Tempo(beatsPerSecond: 1)),
        ])
        #expect(score.effectiveQuarterBpm(at: .beat(measureIndex: 1, tickInMeasure: 240)) == 60)
        #expect(score.effectiveQuarterBpm(at: nil) == 120)
        #expect(abs(score.notatedDurationSeconds - 6) < 1e-9)
    }
}
