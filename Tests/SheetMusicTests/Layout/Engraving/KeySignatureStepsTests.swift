#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicLayout
import Testing

@Suite("KeySignatureSteps")
struct KeySignatureStepsTests {
    @Test func sharpsAndFlatsCoverSevenAccidentals() {
        #expect(KeySignatureSteps.sharps.count == 7)
        #expect(KeySignatureSteps.flats.count == 7)
    }

    @Test func sharpOrderStartsAtFSharpEndsAtBSharp() {
        // F♯ sits on the top line (step 4); B♯ ends on the middle line
        // (step 0).
        #expect(KeySignatureSteps.sharps.first == 4)
        #expect(KeySignatureSteps.sharps.last == 0)
    }

    @Test func flatOrderStartsAtBFlatEndsAtFFlat() {
        // B♭ sits on the middle line (step 0); F♭ ends 1.5 spaces below
        // (step -3).
        #expect(KeySignatureSteps.flats.first == 0)
        #expect(KeySignatureSteps.flats.last == -3)
    }

    @Test func advanceIs1Point4Sp() {
        let sp: CGFloat = 5
        #expect(KeySignatureSteps.advance(sp: sp) == 7)
    }

    @Test func stepDyFlipsSignForYDown() {
        let sp: CGFloat = 4
        // Positive step = up = negative dy.
        #expect(KeySignatureSteps.stepDy(step: 2, sp: sp) == -4)
        #expect(KeySignatureSteps.stepDy(step: 0, sp: sp) == 0)
        #expect(KeySignatureSteps.stepDy(step: -1, sp: sp) == 2)
    }
}
