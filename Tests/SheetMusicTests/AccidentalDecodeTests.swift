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
        // A microtonal glyph stores the natural letter (MuseScore's `AccidentalVal::NATURAL`) — the three-quarter-tone
        // flat included — and puts the whole alteration in `centOffset`.
        #expect(Accidental.mirroredFlat.semitoneOffset == 0)
        #expect(Accidental.flatArrowDown.semitoneOffset == 0)
        #expect(Accidental.sori.semitoneOffset == 0)
        // Wyschnegradsky's six twelfths is the one microtonal glyph that IS a semitone.
        #expect(Accidental.sixTwelfthFlat.semitoneOffset == -1)
        #expect(Accidental.sixTwelfthSharp.semitoneOffset == 1)
    }

    @Test func `cent offsets are MuseScore's`() {
        for standard: Accidental in [
            .flat, .natural, .sharp, .doubleSharp, .doubleFlat, .tripleSharp, .tripleFlat,
            .naturalFlat, .naturalSharp, .sharpSharp,
        ] {
            #expect(standard.centOffset == 0, "\(standard)")
        }
        #expect(Accidental.flatArrowUp.centOffset == -50) // a flat raised a quarter tone: B♮ − 50
        #expect(Accidental.flatArrowDown.centOffset == -150) // three-quarter-tone flat
        #expect(Accidental.sharpArrowUp.centOffset == 150)
        #expect(Accidental.mirroredFlat.centOffset == -50)
        #expect(Accidental.sharpSlash4.centOffset == 150)
        #expect(Accidental.flatSlash2.centOffset == -89)
        #expect(Accidental.koron.centOffset == -67)
        #expect(Accidental.elevenTwelfthSharp.centOffset == 183)
        #expect(Accidental.sixTwelfthFlat.centOffset == 0)
        #expect(Accidental.sagittalFlat.centOffset == -100)
        #expect(Accidental.fiveCommaSharp.centOffset == 111.1)
        #expect(Accidental.flat53.centOffset == -10.9)
        // MuseScore's zeros: it plays these glyphs at the stored pitch.
        #expect(Accidental.flatOneArrowDown.centOffset == 0)
        #expect(Accidental.quarterFlatEqualTempered.centOffset == 0)
        #expect(Accidental.enharmonicTilde.centOffset == 0)
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
