@testable import SheetMusicCore
import Testing

/// Each staff remembers its effective measure durations until its measures change (`Staff+MeasureDurationCache.swift`).
/// The remembered table must give the answer a fresh walk gives — before and after any change to the bars — and must
/// not make two equal staves compare unequal.
struct StaffMeasureDurationCacheTests {
    private static let fourFour = Fraction(numerator: 4, denominator: 4)
    private static let threeFour = Fraction(numerator: 3, denominator: 4)
    private static let sixEight = Fraction(numerator: 6, denominator: 8)

    private static func bar(_ timeSignature: (Int, Int)? = nil, actualLength: Fraction? = nil) -> Measure {
        var elements: [VoiceElement] = []
        if let (numerator, denominator) = timeSignature {
            elements.append(.timeSignature(TimeSignature(numerator: numerator, denominator: denominator)))
        }
        elements.append(.rest(duration: .quarter))
        elements.append(.rest(duration: .quarter))
        var measure = Measure(voices: [Voice(elements: elements)])
        measure.actualLength = actualLength
        return measure
    }

    private static func score(staves: [[Measure]]) -> Score {
        Score(
            division: 480,
            parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: IdentifiedArray(staves.map { Staff(measures: $0) }),
            )],
            systemMeasures: IdentifiedArray(Array(repeating: SystemMeasure(), count: staves.first?.count ?? 0)),
        )
    }

    @Test func `the remembered table is the table a fresh walk builds`() {
        let shapes: [[Measure]] = [
            [],
            [Self.bar(), Self.bar()],
            [Self.bar((3, 4)), Self.bar(), Self.bar((6, 8)), Self.bar()],
            // A pickup: an `actualLength` shorter than the prevailing time signature.
            [Self.bar((4, 4), actualLength: Fraction(numerator: 1, denominator: 8)), Self.bar(), Self.bar()],
        ]
        for measures in shapes {
            let staff = Staff(measures: measures)
            #expect(staff.measureDurations == measures.effectiveMeasureDurations())
            // Asked again, from the box this time.
            #expect(staff.measureDurations == measures.effectiveMeasureDurations())
        }
    }

    /// `actualLength` is per bar, so two staves of one score can differ; each answers from its own bars.
    @Test func `each staff answers from its own bars`() {
        let score = Self.score(staves: [
            [Self.bar((4, 4)), Self.bar()],
            [Self.bar((4, 4)), Self.bar(actualLength: Self.threeFour)],
        ])
        let upper = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let lower = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        #expect(score.effectiveMeasureDuration(at: upper, measureIndex: 1) == Self.fourFour)
        #expect(score.effectiveMeasureDuration(at: lower, measureIndex: 1) == Self.threeFour)
        #expect(score.effectiveMeasureDuration(at: lower, measureIndex: 9) == Self.fourFour)
        #expect(score.effectiveMeasureDuration(at: StaffAddress(partIndex: 5, staffIndexInPart: 0), measureIndex: 0)
            == Self.fourFour)
    }

    /// Every way of changing the bars drops the remembered table: an element written into a bar in place, a bar's
    /// `actualLength`, a bar inserted, the whole list replaced.
    @Test func `a change to the bars is answered with the new durations`() {
        var staff = Staff(measures: [Self.bar((4, 4)), Self.bar(), Self.bar()])
        #expect(staff.measureDurations == [Self.fourFour, Self.fourFour, Self.fourFour])

        // An element of the bar rewritten in place: its first rest becomes a 3/4 time signature.
        staff.measures[1].voices[0].elements.updateValue(at: 0) {
            $0 = .timeSignature(TimeSignature(numerator: 3, denominator: 4))
        }
        #expect(staff.measureDurations == [Self.fourFour, Self.threeFour, Self.threeFour])

        staff.measures[2].actualLength = Self.sixEight
        #expect(staff.measureDurations == [Self.fourFour, Self.threeFour, Self.sixEight])

        staff.measures.insert(Self.bar((6, 8)), at: 0)
        #expect(staff.measureDurations == staff.measures.effectiveMeasureDurations())
        #expect(staff.measureDurations.first == Self.sixEight)

        staff.measures = [Self.bar((3, 4))]
        #expect(staff.measureDurations == [Self.threeFour])
    }

    /// The questions the cache serves read the new bars through the score too, not only through the staff.
    @Test func `the score's timing questions follow a change to the bars`() {
        var score = Self.score(staves: [[Self.bar((4, 4)), Self.bar()]])
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let secondRest = VoiceElementID(staff: address, measureIndex: 1, voiceIndex: 0, elementIndex: 1)
        #expect(score.effectiveMeasureDuration(at: address, measureIndex: 1) == Self.fourFour)
        #expect(score.onset(of: secondRest)?.tick == 480)

        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { $0.measures[1].actualLength = Self.threeFour }
        }
        #expect(score.effectiveMeasureDuration(at: address, measureIndex: 1) == Self.threeFour)
        #expect(score.effectiveMeasureDurations() == [Self.fourFour, Self.threeFour])
        #expect(score.end(of: secondRest)?.tick == 960)
    }

    /// A copy shares the box only until one of them changes its bars; the other keeps its own answer.
    @Test func `a changed copy leaves the original's table alone`() {
        let original = Staff(measures: [Self.bar((4, 4)), Self.bar()])
        #expect(original.measureDurations == [Self.fourFour, Self.fourFour])
        var copy = original
        copy.measures[0].actualLength = Self.threeFour
        #expect(copy.measureDurations == [Self.threeFour, Self.fourFour])
        #expect(original.measureDurations == [Self.fourFour, Self.fourFour])
    }

    /// The cache is not part of the value: whether a staff has built its table never makes it unequal to another.
    @Test func `equal staves stay equal whatever their caches hold`() {
        let built = Staff(measures: [Self.bar((3, 4)), Self.bar()])
        _ = built.measureDurations
        let unbuilt = Staff(measures: [Self.bar((3, 4)), Self.bar()])
        #expect(built == unbuilt)
        _ = unbuilt.measureDurations
        #expect(built == unbuilt)
        let other = Staff(measures: [Self.bar((4, 4)), Self.bar()])
        #expect(built != other)
    }

    /// Read from many tasks at once, before anything has built it: every reader gets the same table.
    @Test func `concurrent first reads agree`() async {
        let staff = Staff(measures: (0 ..< 64).map { $0 % 8 == 0 ? Self.bar((3, 4)) : Self.bar() })
        let expected = staff.measures.effectiveMeasureDurations()
        let answers = await withTaskGroup(of: [Fraction].self) { group in
            for _ in 0 ..< 16 {
                group.addTask { staff.measureDurations }
            }
            var answers: [[Fraction]] = []
            for await answer in group {
                answers.append(answer)
            }
            return answers
        }
        #expect(answers.count == 16)
        #expect(answers.allSatisfy { $0 == expected })
    }
}
