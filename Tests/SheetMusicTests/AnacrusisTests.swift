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
}
