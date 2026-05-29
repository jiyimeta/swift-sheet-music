@testable import SheetMusicCore
import Testing

struct MeterChangePreservesMeasureRestTests {
    /// Per spec §"Time-signature changes and measure-rest identity":
    /// a `.measure` rest re-resolves against whatever meter is in
    /// scope at render time. Construct a Score with three identical
    /// `.measure` rests, then run it under 4/4 and again under 3/4
    /// (only the first measure's TimeSignature differs); the MIDI
    /// renderer should produce 3 × bar-length ticks in each case,
    /// scaling automatically with the meter.
    @Test func measureRestTickCountTracksPrevailingMeter() {
        let division = 480

        func makeScore(numerator: Int, denominator: Int) -> Score {
            let firstMeasureElements: [VoiceElement] = [
                .timeSignature(TimeSignature(
                    numerator: numerator, denominator: denominator,
                )),
                .rest(duration: .measure),
            ]
            let restMeasure = Measure(voices: [Voice(elements: [
                .rest(duration: .measure),
            ])])
            let measures = [
                Measure(voices: [Voice(elements: firstMeasureElements)]),
                restMeasure,
                restMeasure,
            ]
            return Score(
                division: division,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
                systemMeasures: Array(
                    repeating: SystemMeasure(), count: measures.count,
                ),
            )
        }

        // Resolution check via the helper directly: we don't depend
        // on the MIDI renderer to verify the model behavior.
        let fourFour = makeScore(numerator: 4, denominator: 4)
        let threeFour = makeScore(numerator: 3, denominator: 4)

        let f4 = fourFour.effectiveMeasureDurations()
        let f3 = threeFour.effectiveMeasureDurations()
        #expect(f4 == Array(repeating: Fraction(numerator: 4, denominator: 4), count: 3))
        #expect(f3 == Array(repeating: Fraction(numerator: 3, denominator: 4), count: 3))

        // Each measure in 4/4 resolves to 4 quarters = 4 * division ticks.
        // Each measure in 3/4 resolves to 3 quarters = 3 * division ticks.
        let totalTicks4 = f4.reduce(0) { acc, frac in
            acc + NoteDuration.measure
                .resolved(in: frac)
                .ticks(division: division)
        }
        let totalTicks3 = f3.reduce(0) { acc, frac in
            acc + NoteDuration.measure
                .resolved(in: frac)
                .ticks(division: division)
        }
        #expect(totalTicks4 == 3 * 4 * division)
        #expect(totalTicks3 == 3 * 3 * division)
    }
}
