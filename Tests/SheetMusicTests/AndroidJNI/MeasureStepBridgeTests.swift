import Foundation
@testable import SheetMusicAndroidJNI
@testable import SheetMusicCore
import Testing

struct MeasureStepBridgeTests {
    /// Four-measure 4/4 score with quarter notes — mirrors `MeasureStepTests.makeScore()`.
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

    @Test func forwardCursorRoundTripsThroughWire() throws {
        let score = Self.makeScore()
        let handle = scoreTable.insert(score)
        defer { scoreTable.release(handle) }
        let from = ScoreCursorCodec.encode(.beat(measureIndex: 0, tickInMeasure: 0))
        let out = nativeStepMeasureCursor(scoreHandle: handle, fromCursorBytes: from, direction: 1)
        #expect(try ScoreCursorCodec.decode(out) == .beat(measureIndex: 1, tickInMeasure: 0))
    }

    @Test func backwardCursorRoundTripsThroughWire() throws {
        let score = Self.makeScore()
        let handle = scoreTable.insert(score)
        defer { scoreTable.release(handle) }
        // From measure 2, tick 0 (within the first beat) → previous measure's downbeat.
        let from = ScoreCursorCodec.encode(.beat(measureIndex: 2, tickInMeasure: 0))
        let out = nativeStepMeasureCursor(scoreHandle: handle, fromCursorBytes: from, direction: 0)
        #expect(try ScoreCursorCodec.decode(out) == .beat(measureIndex: 1, tickInMeasure: 0))
    }

    @Test func unknownHandleReturnsInputBytes() {
        let from = ScoreCursorCodec.encode(.beat(measureIndex: 3, tickInMeasure: 120))
        let out = nativeStepMeasureCursor(scoreHandle: 999_999, fromCursorBytes: from, direction: 1)
        #expect(out == from)
    }
}
