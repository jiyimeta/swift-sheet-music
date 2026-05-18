import Foundation
@testable import SheetMusicCore
import Testing

struct DiatonicPitchClassesTests {
    private func pcs(_ key: Int) -> Set<Int> {
        KeySignature(concertKey: key).diatonicPitchClasses
    }

    @Test func cMajor_zero_sharps() {
        #expect(pcs(0) == [0, 2, 4, 5, 7, 9, 11])
    }

    @Test func gMajor_plus_one() {
        #expect(pcs(1) == [0, 2, 4, 6, 7, 9, 11])
    }

    @Test func dMajor_plus_two() {
        #expect(pcs(2) == [1, 2, 4, 6, 7, 9, 11])
    }

    @Test func aMajor_plus_three() {
        #expect(pcs(3) == [1, 2, 4, 6, 8, 9, 11])
    }

    @Test func eMajor_plus_four() {
        #expect(pcs(4) == [1, 3, 4, 6, 8, 9, 11])
    }

    @Test func bMajor_plus_five() {
        #expect(pcs(5) == [1, 3, 4, 6, 8, 10, 11])
    }

    @Test func fSharpMajor_plus_six() {
        #expect(pcs(6) == [1, 3, 5, 6, 8, 10, 11])
    }

    @Test func cSharpMajor_plus_seven() {
        #expect(pcs(7) == [0, 1, 3, 5, 6, 8, 10])
    }

    @Test func fMajor_minus_one() {
        #expect(pcs(-1) == [0, 2, 4, 5, 7, 9, 10])
    }

    @Test func bFlatMajor_minus_two() {
        #expect(pcs(-2) == [0, 2, 3, 5, 7, 9, 10])
    }

    @Test func eFlatMajor_minus_three() {
        #expect(pcs(-3) == [0, 2, 3, 5, 7, 8, 10])
    }

    @Test func aFlatMajor_minus_four() {
        #expect(pcs(-4) == [0, 1, 3, 5, 7, 8, 10])
    }

    @Test func dFlatMajor_minus_five() {
        #expect(pcs(-5) == [0, 1, 3, 5, 6, 8, 10])
    }

    @Test func gFlatMajor_minus_six() {
        #expect(pcs(-6) == [1, 3, 5, 6, 8, 10, 11])
    }

    @Test func cFlatMajor_minus_seven() {
        #expect(pcs(-7) == [1, 3, 4, 6, 8, 10, 11])
    }

    @Test func every_signature_returns_exactly_seven_pcs() {
        for k in -7 ... 7 {
            #expect(pcs(k).count == 7)
        }
    }
}
