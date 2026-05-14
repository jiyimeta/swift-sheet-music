@testable import SheetMusicCore
import Testing

struct EffectiveMeasureDurationsTests {
    private static func makeScore(
        timeSignaturesByMeasure: [(Int, Int)?],
        actualLengths: [Fraction?] = [],
    ) -> Score {
        let measures = timeSignaturesByMeasure.enumerated().map { i, ts -> Measure in
            var voices: [VoiceElement] = []
            if let (n, d) = ts {
                voices.append(.timeSignature(TimeSignature(numerator: n, denominator: d)))
            }
            voices.append(.rest(duration: .whole))
            var m = Measure(voices: [Voice(elements: voices)])
            if i < actualLengths.count, let len = actualLengths[i] {
                m.actualLength = len
            }
            return m
        }
        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: measures)],
            )],
            systemMeasures: Array(repeating: SystemMeasure(), count: measures.count),
        )
    }

    @Test func defaultsToFourFourWhenNoTimeSignature() {
        let s = Self.makeScore(timeSignaturesByMeasure: [nil, nil])
        let durations = s.effectiveMeasureDurations()
        #expect(durations == [
            Fraction(numerator: 4, denominator: 4),
            Fraction(numerator: 4, denominator: 4),
        ])
    }

    @Test func picksUpInitialTimeSignature() {
        let s = Self.makeScore(timeSignaturesByMeasure: [(6, 4), nil, nil])
        let durations = s.effectiveMeasureDurations()
        #expect(durations == Array(repeating: Fraction(numerator: 6, denominator: 4), count: 3))
    }

    @Test func tracksMidScoreTimeSignatureChange() {
        let s = Self.makeScore(timeSignaturesByMeasure: [(4, 4), nil, (3, 4), nil])
        let durations = s.effectiveMeasureDurations()
        #expect(durations == [
            Fraction(numerator: 4, denominator: 4),
            Fraction(numerator: 4, denominator: 4),
            Fraction(numerator: 3, denominator: 4),
            Fraction(numerator: 3, denominator: 4),
        ])
    }

    @Test func actualLengthOverridesPrevailingTimeSignature() {
        let s = Self.makeScore(
            timeSignaturesByMeasure: [(4, 4), nil, nil],
            actualLengths: [nil, Fraction(numerator: 2, denominator: 4), nil],
        )
        let durations = s.effectiveMeasureDurations()
        #expect(durations == [
            Fraction(numerator: 4, denominator: 4),
            Fraction(numerator: 2, denominator: 4),
            Fraction(numerator: 4, denominator: 4),
        ])
    }
}
