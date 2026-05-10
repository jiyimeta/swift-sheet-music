@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite struct DurationInterpretationTests {
    // MARK: plain durations

    @available(macOS 15.0, iOS 16.0, *)
    @Test func plainDurationsHaveZeroDots() {
        #expect(DurationInterpretation.split(.whole) == (.whole, 0))
        #expect(DurationInterpretation.split(.half) == (.half, 0))
        #expect(DurationInterpretation.split(.quarter) == (.quarter, 0))
        #expect(DurationInterpretation.split(.eighth) == (.eighth, 0))
    }

    // MARK: dotted decompositions

    @available(macOS 15.0, iOS 16.0, *)
    @Test func dottedHalf() {
        let dur = NoteDuration.fraction(Fraction(numerator: 3, denominator: 4))
        let split = DurationInterpretation.split(dur)
        #expect(split.base == .half)
        #expect(split.dots == 1)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func doubleDottedHalf() {
        let dur = NoteDuration.fraction(Fraction(numerator: 7, denominator: 8))
        let split = DurationInterpretation.split(dur)
        #expect(split.base == .half)
        #expect(split.dots == 2)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func doubleDottedWhole() {
        let dur = NoteDuration.fraction(Fraction(numerator: 7, denominator: 4))
        let split = DurationInterpretation.split(dur)
        #expect(split.base == .whole)
        #expect(split.dots == 2)
    }

    // MARK: tuplet un-scaling

    @available(macOS 15.0, iOS 16.0, *)
    @Test func tripletEighthIsEighth() {
        // 1/8 × 2/3 = 1/12 — un-scale via (3,2) tuplet ratio.
        let dur = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))
        let split = DurationInterpretation.split(dur)
        #expect(split.base == .eighth)
        #expect(split.dots == 0)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func quintupletSixteenthIsSixteenth() {
        // 1/16 × 4/5 = 1/20 — un-scale via (5,4) tuplet ratio.
        let dur = NoteDuration.fraction(Fraction(numerator: 1, denominator: 20))
        let split = DurationInterpretation.split(dur)
        #expect(split.base == .sixteenth)
        #expect(split.dots == 0)
    }

    // MARK: regression — multi-measure-rest fractions

    /// MuseScore writes pre-collapsed multi-measure rests as a single
    /// `<Rest>` whose `<duration>` carries the cumulative tick span,
    /// e.g. `8/4` for a 2-bar 4/4 mmRest body. Before the fix the
    /// tuplet fallback in `split` falsely matched the (7, 8) septuplet
    /// scale and reported `(.whole, 2)` — a double-dotted whole rest.
    /// These regular (power-of-two-denominator) fractions must NOT
    /// produce phantom dots.
    @available(macOS 15.0, iOS 16.0, *)
    @Test func multiMeasureRestFractionsHaveNoDots() {
        let cases = [
            Fraction(numerator: 8, denominator: 4),
            Fraction(numerator: 12, denominator: 4),
            Fraction(numerator: 16, denominator: 4),
            Fraction(numerator: 24, denominator: 4),
            Fraction(numerator: 32, denominator: 4),
        ]
        for f in cases {
            let split = DurationInterpretation.split(.fraction(f))
            #expect(
                split.dots == 0,
                "fraction \(f.numerator)/\(f.denominator) should not be dotted"
            )
            #expect(
                split.base == .whole,
                "fraction \(f.numerator)/\(f.denominator) should render as whole rest"
            )
        }
    }
}
