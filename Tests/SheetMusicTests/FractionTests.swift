@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite struct FractionTests {
    @Test func reducedOnInit() {
        let f = Fraction(numerator: 2, denominator: 4)
        #expect(f.numerator == 1)
        #expect(f.denominator == 2)
    }

    @Test func equalityIgnoresUnreducedForm() {
        #expect(Fraction(numerator: 2, denominator: 4) == Fraction(numerator: 1, denominator: 2))
    }

    @Test func addCommonDenominator() {
        let sum = Fraction(numerator: 1, denominator: 4) + Fraction(numerator: 1, denominator: 4)
        #expect(sum == Fraction(numerator: 1, denominator: 2))
    }

    @Test func addDifferentDenominator() {
        let sum = Fraction(numerator: 1, denominator: 3) + Fraction(numerator: 1, denominator: 6)
        #expect(sum == Fraction(numerator: 1, denominator: 2))
    }

    @Test func tickConversion() {
        #expect(Fraction(numerator: 1, denominator: 4).ticks(division: 480) == 480)
        #expect(Fraction(numerator: 4, denominator: 4).ticks(division: 480) == 1920)
    }
}
