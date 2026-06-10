@testable import SheetMusicCore
import Testing

/// Tests for `Score.rehearsalMarks()` / `RehearsalMarkEntry`.
///
/// No pre-existing fixture file contains `<RehearsalMark>` elements, so
/// scores are constructed inline — the same approach used by
/// `RehearsalMarkTests.swift` for the MSCX/MIDI rehearsal-mark tests.
struct RehearsalMarksTests {
    // MARK: - Helpers

    private static func makeInstrument() -> Instrument {
        Instrument(id: "voice", articulations: [InstrumentArticulation()])
    }

    /// Four-measure 4/4 score with rehearsal marks "A" at measure 0 downbeat and "B" at measure 2 downbeat.
    private static func scoreWithTwoMarks() -> Score {
        let chord = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(chord), .chord(chord), .chord(chord), .chord(chord),
        ])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure, measure, measure, measure])
        let part = Part(id: "P1", instrument: makeInstrument(), staves: [staff])
        let markA = RehearsalMark(text: "A")
        let markB = RehearsalMark(text: "B")
        return Score(
            division: 480,
            parts: [part],
            systemMeasures: [
                SystemMeasure(elements: [
                    PositionedSystemElement(position: .start, element: .rehearsalMark(markA)),
                ]),
                SystemMeasure(),
                SystemMeasure(elements: [
                    PositionedSystemElement(position: .start, element: .rehearsalMark(markB)),
                ]),
                SystemMeasure(),
            ],
        )
    }

    /// Single-measure score with no rehearsal marks, to cover the empty case.
    private static func scoreWithNoMarks() -> Score {
        let chord = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        let voice = Voice(elements: [.chord(chord)])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(id: "P1", instrument: makeInstrument(), staves: [staff])
        return Score(
            division: 480,
            parts: [part],
            systemMeasures: [SystemMeasure()],
        )
    }

    // MARK: - Tests

    @Test func marksAreOrderedWithFractionsInUnitRange() {
        let score = Self.scoreWithTwoMarks()
        let marks = score.rehearsalMarks()
        #expect(marks.count >= 2)
        #expect(marks.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
        #expect(marks.map(\.fraction) == marks.map(\.fraction).sorted())
        for entry in marks {
            if case .beat = entry.cursor { } else {
                Issue.record("Expected .beat cursor, got \(entry.cursor)")
            }
        }
    }

    @Test func markTextsMatchSource() {
        let score = Self.scoreWithTwoMarks()
        let marks = score.rehearsalMarks()
        #expect(marks.count == 2)
        #expect(marks[0].text == "A")
        #expect(marks[1].text == "B")
    }

    @Test func firstMarkFractionIsZero() {
        let score = Self.scoreWithTwoMarks()
        let marks = score.rehearsalMarks()
        // "A" sits at measure 0, tick 0 → seconds(at:) == 0 → fraction == 0.
        #expect(!marks.isEmpty)
        #expect(marks[0].fraction == 0.0)
    }

    @Test func secondMarkFractionIsHalfway() {
        let score = Self.scoreWithTwoMarks()
        let marks = score.rehearsalMarks()
        // "B" sits at measure 2 of 4 equal measures → fraction ≈ 0.5.
        #expect(marks.count >= 2)
        #expect(abs(marks[1].fraction - 0.5) < 1e-9)
    }

    @Test func cursorMeasureIndexMatchesMarkPosition() {
        let score = Self.scoreWithTwoMarks()
        let marks = score.rehearsalMarks()
        #expect(marks.count == 2)
        #expect(marks[0].cursor.measureIndex == 0)
        #expect(marks[1].cursor.measureIndex == 2)
    }

    @Test func emptyWhenNoMarks() {
        let score = Self.scoreWithNoMarks()
        #expect(score.rehearsalMarks().isEmpty)
    }
}
