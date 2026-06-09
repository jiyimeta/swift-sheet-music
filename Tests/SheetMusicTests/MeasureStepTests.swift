@testable import SheetMusicCore
import Testing

/// Tests for `Score.cursorSteppingMeasure(from:direction:)` / `MeasureStepDirection`.
struct MeasureStepTests {
    // MARK: - Helpers

    /// Four-measure 4/4 score with quarter notes — a simple multi-measure fixture.
    /// All measures are structurally identical so `beatTicks(atMeasure:)` is non-nil and > 0
    /// for every measure index, including 2.
    private static func makeScore() -> Score {
        let chord = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(chord), .chord(chord), .chord(chord), .chord(chord),
        ])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure, measure, measure, measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "voice", articulations: [InstrumentArticulation()]),
            staves: [staff],
        )
        return Score(
            division: 480,
            parts: [part],
            systemMeasures: Array(repeating: SystemMeasure(), count: 4),
        )
    }

    // MARK: - Forward

    @Test func forwardAdvancesOneMeasureAndClampsAtEnd() {
        let score = Self.makeScore()
        let last = score.effectiveMeasureDurations().count - 1
        #expect(
            score.cursorSteppingMeasure(
                from: .beat(measureIndex: 0, tickInMeasure: 0), direction: .forward,
            ) == .beat(measureIndex: 1, tickInMeasure: 0),
        )
        #expect(
            score.cursorSteppingMeasure(
                from: .beat(measureIndex: last, tickInMeasure: 0), direction: .forward,
            ) == .beat(measureIndex: last, tickInMeasure: 0),
        )
    }

    @Test func forwardFromMiddleMeasure() {
        let score = Self.makeScore()
        #expect(
            score.cursorSteppingMeasure(
                from: .beat(measureIndex: 2, tickInMeasure: 0), direction: .forward,
            ) == .beat(measureIndex: 3, tickInMeasure: 0),
        )
    }

    // MARK: - Backward

    @Test func backwardRestartsCurrentMeasureWhenPastFirstBeat() throws {
        let score = Self.makeScore()
        // beatTicks(atMeasure: 2) == 480 for 4/4, division 480.
        let beat = try #require(score.beatTicks(atMeasure: 2))
        #expect(beat > 0)
        // Cursor is at tick == beat (at or past the first beat threshold) → restart current measure.
        #expect(
            score.cursorSteppingMeasure(
                from: .beat(measureIndex: 2, tickInMeasure: beat), direction: .backward,
            ) == .beat(measureIndex: 2, tickInMeasure: 0),
        )
        // Cursor is past the first beat → restart current measure.
        #expect(
            score.cursorSteppingMeasure(
                from: .beat(measureIndex: 2, tickInMeasure: beat + 1), direction: .backward,
            ) == .beat(measureIndex: 2, tickInMeasure: 0),
        )
    }

    @Test func backwardGoesToPreviousMeasureWithinFirstBeat() throws {
        let score = Self.makeScore()
        // Cursor at tick 0 (within the first beat) → go to previous measure's downbeat.
        #expect(
            score.cursorSteppingMeasure(
                from: .beat(measureIndex: 2, tickInMeasure: 0), direction: .backward,
            ) == .beat(measureIndex: 1, tickInMeasure: 0),
        )
        // Cursor at tick < beat (within the first beat interval) → also go to previous.
        let beat = try #require(score.beatTicks(atMeasure: 2))
        if beat > 1 {
            #expect(
                score.cursorSteppingMeasure(
                    from: .beat(measureIndex: 2, tickInMeasure: beat - 1), direction: .backward,
                ) == .beat(measureIndex: 1, tickInMeasure: 0),
            )
        }
    }

    @Test func backwardClampsToMeasureZeroAtStart() {
        let score = Self.makeScore()
        // Already at measure 0, tick 0 → clamp to 0.
        #expect(
            score.cursorSteppingMeasure(
                from: .beat(measureIndex: 0, tickInMeasure: 0), direction: .backward,
            ) == .beat(measureIndex: 0, tickInMeasure: 0),
        )
    }
}
