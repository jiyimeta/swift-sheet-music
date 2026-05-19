import CoreGraphics
@testable import SheetMusicLayout
import Testing

@Suite("TimeSignatureLayout")
struct TimeSignatureLayoutTests {
    @Test func digitAdvanceIs1Point4Sp() {
        #expect(TimeSignatureLayout.digitAdvance(sp: 5) == 7)
    }

    @Test func numeratorAndDenominatorAreOneSpaceFromMiddle() {
        #expect(TimeSignatureLayout.numeratorDy(sp: 4) == -4)
        #expect(TimeSignatureLayout.denominatorDy(sp: 4) == 4)
    }

    @Test func singleDigitOverSingleDigitHasNoCenteringOffset() {
        let (numDx, denDx, max) = TimeSignatureLayout.rowOffsets(
            numerator: 4, denominator: 4, sp: 5,
        )
        #expect(numDx == 0)
        #expect(denDx == 0)
        // One digit × 1.4 sp advance.
        #expect(max == 7)
    }

    @Test func twoDigitNumeratorCentresSingleDigitDenominator() {
        // "12" over "8": numerator row is 2 advances wide, denominator
        // is 1 advance wide; denominator shifts right by half an advance
        // to centre.
        let (numDx, denDx, max) = TimeSignatureLayout.rowOffsets(
            numerator: 12, denominator: 8, sp: 5,
        )
        let advance: CGFloat = 7
        #expect(numDx == 0)
        #expect(denDx == advance / 2)
        #expect(max == 2 * advance)
    }
}
