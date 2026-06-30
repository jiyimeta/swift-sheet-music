import Foundation
@testable import SheetMusicCore
import Testing

struct AccidentalDecodeTests {
    @Test func standardRoundTrips() {
        #expect(Accidental(mscxSubtype: "accidentalSharp") == .sharp)
        #expect(Accidental.sharp.mscxSubtype == "accidentalSharp")
        #expect(Accidental(mscxSubtype: "accidentalFlat") == .flat)
        #expect(Accidental.flat.mscxSubtype == "accidentalFlat")
        #expect(Accidental(mscxSubtype: "accidentalNatural") == .natural)
        #expect(Accidental(mscxSubtype: "accidentalDoubleSharp") == .doubleSharp)
        #expect(Accidental(mscxSubtype: "accidentalDoubleFlat") == .doubleFlat)
    }

    @Test func quarterToneDecodes() {
        // Stein-Zimmermann quarter-tone flat
        #expect(Accidental(mscxSubtype: "accidentalQuarterToneFlatStein") == .mirroredFlat)
        // Gould arrow quarter-tone
        #expect(Accidental(mscxSubtype: "accidentalQuarterToneFlatArrowUp") == .flatArrowUp)
        // AEU
        #expect(Accidental(mscxSubtype: "accidentalBuyukMucennebFlat") == .flatSlash2)
        // Persian
        #expect(Accidental(mscxSubtype: "accidentalSori") == .sori)
        #expect(Accidental(mscxSubtype: "accidentalKoron") == .koron)
        // Sagittal
        #expect(Accidental(mscxSubtype: "accSagittal5v7KleismaDown") == .sagittal5v7KleismaDown)
        // Turkish folk
        #expect(Accidental(mscxSubtype: "accidental1CommaFlat") == .oneCommaFlat)
        // Wyschnegradsky
        #expect(Accidental(mscxSubtype: "accidentalWyschnegradsky6TwelfthsFlat") == .sixTwelfthFlat)
    }

    @Test func unknownIsNil() {
        #expect(Accidental(mscxSubtype: "accidentalBogus") == nil)
        #expect(Accidental(mscxSubtype: "") == nil)
    }

    @Test func semitoneOffsets() {
        #expect(Accidental.tripleFlat.semitoneOffset == -3)
        #expect(Accidental.doubleFlat.semitoneOffset == -2)
        #expect(Accidental.flat.semitoneOffset == -1)
        #expect(Accidental.naturalFlat.semitoneOffset == -1)
        #expect(Accidental.natural.semitoneOffset == 0)
        #expect(Accidental.sharp.semitoneOffset == 1)
        #expect(Accidental.naturalSharp.semitoneOffset == 1)
        #expect(Accidental.doubleSharp.semitoneOffset == 2)
        #expect(Accidental.sharpSharp.semitoneOffset == 2)
        #expect(Accidental.tripleSharp.semitoneOffset == 3)
        // Microtonal → integer part (0)
        #expect(Accidental.mirroredFlat.semitoneOffset == 0)
        #expect(Accidental.sori.semitoneOffset == 0)
    }

    @Test func brackets() {
        // Qualify .none explicitly to avoid Optional.none type inference.
        #expect(AccidentalBracket(rawValue: 0) == AccidentalBracket.none)
        #expect(AccidentalBracket(rawValue: 1) == .parenthesis)
        #expect(AccidentalBracket(rawValue: 2) == .bracket)
        #expect(AccidentalBracket(rawValue: 99) == nil)
    }

    @Test func allCasesHaveUniqueRawValues() {
        let rawValues = Accidental.allCases.map(\.rawValue)
        let unique = Set(rawValues)
        #expect(rawValues.count == unique.count, "Duplicate rawValues found")
    }
}

// Safety-net: every Accidental case's rawValue (= SymId name) must exist in the
// SMuFL byName resolver. A failure here means a typo'd SymId name — fix the table.
// Apple-only because SheetMusicLayout is not Android-compatible.
#if !os(Android)
    @testable import SheetMusicLayout

    struct AccidentalSymIdSafetyNetTests {
        @Test func allCasesHaveValidSymId() {
            for acc in Accidental.allCases {
                #expect(
                    SMuFLCodepoint.byName(acc.mscxSubtype) != nil,
                    "\(acc): '\(acc.mscxSubtype)' not found in SMuFL byName table",
                )
            }
        }
    }
#endif
