import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

@Suite struct AnacrusisTests {
    @Test func measureCarriesActualLengthAndIrregular() {
        let pickup = Measure(
            voices: [],
            actualLength: Fraction(numerator: 1, denominator: 4),
            irregular: true
        )
        #expect(pickup.actualLength == Fraction(numerator: 1, denominator: 4))
        #expect(pickup.irregular == true)

        let normal = Measure(voices: [])
        #expect(normal.actualLength == nil)
        #expect(normal.irregular == false)

        // Equatable should pick up the new fields.
        #expect(pickup != Measure(voices: [], irregular: true))
        #expect(pickup != Measure(
            voices: [],
            actualLength: Fraction(numerator: 1, denominator: 4)
        ))
    }

    @Test func displayedMeasureNumberSkipsIrregular() {
        let staff = Staff(measures: [
            Measure(voices: [Voice(elements: [])], irregular: true),
            Measure(voices: [Voice(elements: [])]),
            Measure(voices: [Voice(elements: [])]),
        ])
        let part = Part(
            id: "1",
            instrument: Instrument(id: "x", longName: "Piano"),
            staves: [staff]
        )
        let score = Score(division: 480, parts: [part])

        #expect(score.displayedMeasureNumber(at: 0) == nil)
        #expect(score.displayedMeasureNumber(at: 1) == 1)
        #expect(score.displayedMeasureNumber(at: 2) == 2)

        let regular = Score(division: 480, parts: [Part(
            id: "1",
            instrument: Instrument(id: "x", longName: "Piano"),
            staves: [Staff(measures: [
                Measure(voices: [Voice(elements: [])]),
                Measure(voices: [Voice(elements: [])]),
            ])]
        )])
        #expect(regular.displayedMeasureNumber(at: 0) == 1)
        #expect(regular.displayedMeasureNumber(at: 1) == 2)
    }
}
