@testable import SheetMusicCore
import Testing

/// `NoteDuration.baseAndDots()` — the exact inverse of `dotted(_:)`, and what `SetDots` decomposes a duration
/// with before handing the base back to `SetChordDuration` / `SetRestDuration`.
@Suite("NoteDuration.baseAndDots()")
struct NoteDurationBaseAndDotsTests {
    @Test("every base with every dot count round-trips through dotted(_:)", arguments: [
        NoteDuration.whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond, .sixtyFourth,
        .oneTwentyEighth, .twoFiftySixth,
    ], [0, 1, 2, 3])
    func roundTrip(base: NoteDuration, dots: Int) throws {
        let decomposed = try #require(base.dotted(dots).baseAndDots())
        #expect(decomposed.base == base)
        #expect(decomposed.dots == dots)
    }

    @Test("an undotted case decomposes to itself with zero dots")
    func undotted() throws {
        #expect(try #require(NoteDuration.quarter.baseAndDots()) == (base: .quarter, dots: 0))
    }

    @Test("the fractions dotted(_:) writes are recognized by value, in any spelling")
    func recognizesDottedFractions() throws {
        // `dotted(1)` on a quarter is 3/8; an equal fraction spelled 6/16 must decompose alike.
        #expect(try #require(NoteDuration.fraction(Fraction(numerator: 3, denominator: 8)).baseAndDots())
            == (base: .quarter, dots: 1))
        #expect(try #require(NoteDuration.fraction(Fraction(numerator: 6, denominator: 16)).baseAndDots())
            == (base: .quarter, dots: 1))
    }

    @Test("a measure rest and an irregular fraction have no decomposition")
    func refusals() {
        #expect(NoteDuration.measure.baseAndDots() == nil)
        // A tuplet-scaled member: `1/12` is no base with any dot count.
        #expect(NoteDuration.fraction(Fraction(numerator: 1, denominator: 12)).baseAndDots() == nil)
        // Four dots is past the ceiling this package writes, so it decomposes to nothing rather than to a base.
        #expect(NoteDuration.quarter.dotted(4).baseAndDots() == nil)
    }
}
