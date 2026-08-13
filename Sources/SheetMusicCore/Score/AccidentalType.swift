import SheetMusicFoundation

/// Visual accidental on a note. Display-only; MIDI pitch is the source of truth.
///
/// `rawValue` equals the SMuFL SymId name (= the MSCX `<Accidental><subtype>` token).
/// So `init?(mscxSubtype:)` and `mscxSubtype` are free one-liners over `rawValue`.
///
/// C++: `mu::engraving::AccidentalType` (`src/engraving/dom/accidental.h:35-212`)
///      `ACC_LIST[]` (`src/engraving/dom/accidental.cpp:51-224`)
public enum Accidental: String, Sendable, CaseIterable {
    // MARK: — Standard

    /// C++: FLAT
    case flat = "accidentalFlat"
    /// C++: NATURAL
    case natural = "accidentalNatural"
    /// C++: SHARP
    case sharp = "accidentalSharp"
    /// C++: SHARP2
    case doubleSharp = "accidentalDoubleSharp"
    /// C++: FLAT2
    case doubleFlat = "accidentalDoubleFlat"
    /// C++: SHARP3
    case tripleSharp = "accidentalTripleSharp"
    /// C++: FLAT3
    case tripleFlat = "accidentalTripleFlat"
    /// C++: NATURAL_FLAT
    case naturalFlat = "accidentalNaturalFlat"
    /// C++: NATURAL_SHARP
    case naturalSharp = "accidentalNaturalSharp"
    /// C++: SHARP_SHARP
    case sharpSharp = "accidentalSharpSharp"

    // MARK: — Gould arrow quartertone

    /// C++: FLAT_ARROW_UP
    case flatArrowUp = "accidentalQuarterToneFlatArrowUp"
    /// C++: FLAT_ARROW_DOWN
    case flatArrowDown = "accidentalThreeQuarterTonesFlatArrowDown"
    /// C++: NATURAL_ARROW_UP
    case naturalArrowUp = "accidentalQuarterToneSharpNaturalArrowUp"
    /// C++: NATURAL_ARROW_DOWN
    case naturalArrowDown = "accidentalQuarterToneFlatNaturalArrowDown"
    /// C++: SHARP_ARROW_UP
    case sharpArrowUp = "accidentalThreeQuarterTonesSharpArrowUp"
    /// C++: SHARP_ARROW_DOWN
    case sharpArrowDown = "accidentalQuarterToneSharpArrowDown"
    /// C++: SHARP2_ARROW_UP
    case sharp2ArrowUp = "accidentalFiveQuarterTonesSharpArrowUp"
    /// C++: SHARP2_ARROW_DOWN
    case sharp2ArrowDown = "accidentalThreeQuarterTonesSharpArrowDown"
    /// C++: FLAT2_ARROW_UP
    case flat2ArrowUp = "accidentalThreeQuarterTonesFlatArrowUp"
    /// C++: FLAT2_ARROW_DOWN
    case flat2ArrowDown = "accidentalFiveQuarterTonesFlatArrowDown"
    /// C++: ARROW_DOWN
    case arrowDown = "accidentalArrowDown"
    /// C++: ARROW_UP
    case arrowUp = "accidentalArrowUp"

    // MARK: — Stein-Zimmermann

    /// C++: MIRRORED_FLAT
    case mirroredFlat = "accidentalQuarterToneFlatStein"
    /// C++: MIRRORED_FLAT2
    case mirroredFlat2 = "accidentalThreeQuarterTonesFlatZimmermann"
    /// C++: SHARP_SLASH
    case sharpSlash = "accidentalQuarterToneSharpStein"
    /// C++: SHARP_SLASH4
    case sharpSlash4 = "accidentalThreeQuarterTonesSharpStein"

    // MARK: — Arel-Ezgi-Uzdilek (AEU)

    /// C++: FLAT_SLASH2
    case flatSlash2 = "accidentalBuyukMucennebFlat"
    /// C++: FLAT_SLASH
    case flatSlash = "accidentalBakiyeFlat"
    /// C++: SHARP_SLASH3
    case sharpSlash3 = "accidentalKucukMucennebSharp"
    /// C++: SHARP_SLASH2
    case sharpSlash2 = "accidentalBuyukMucennebSharp"

    // MARK: — Extended Helmholtz-Ellis (just intonation)

    /// C++: DOUBLE_FLAT_ONE_ARROW_DOWN
    case doubleFlatOneArrowDown = "accidentalDoubleFlatOneArrowDown"
    /// C++: FLAT_ONE_ARROW_DOWN
    case flatOneArrowDown = "accidentalFlatOneArrowDown"
    /// C++: NATURAL_ONE_ARROW_DOWN
    case naturalOneArrowDown = "accidentalNaturalOneArrowDown"
    /// C++: SHARP_ONE_ARROW_DOWN
    case sharpOneArrowDown = "accidentalSharpOneArrowDown"
    /// C++: DOUBLE_SHARP_ONE_ARROW_DOWN
    case doubleSharpOneArrowDown = "accidentalDoubleSharpOneArrowDown"
    /// C++: DOUBLE_FLAT_ONE_ARROW_UP
    case doubleFlatOneArrowUp = "accidentalDoubleFlatOneArrowUp"
    /// C++: FLAT_ONE_ARROW_UP
    case flatOneArrowUp = "accidentalFlatOneArrowUp"
    /// C++: NATURAL_ONE_ARROW_UP
    case naturalOneArrowUp = "accidentalNaturalOneArrowUp"
    /// C++: SHARP_ONE_ARROW_UP
    case sharpOneArrowUp = "accidentalSharpOneArrowUp"
    /// C++: DOUBLE_SHARP_ONE_ARROW_UP
    case doubleSharpOneArrowUp = "accidentalDoubleSharpOneArrowUp"
    /// C++: DOUBLE_FLAT_TWO_ARROWS_DOWN
    case doubleFlatTwoArrowsDown = "accidentalDoubleFlatTwoArrowsDown"
    /// C++: FLAT_TWO_ARROWS_DOWN
    case flatTwoArrowsDown = "accidentalFlatTwoArrowsDown"
    /// C++: NATURAL_TWO_ARROWS_DOWN
    case naturalTwoArrowsDown = "accidentalNaturalTwoArrowsDown"
    /// C++: SHARP_TWO_ARROWS_DOWN
    case sharpTwoArrowsDown = "accidentalSharpTwoArrowsDown"
    /// C++: DOUBLE_SHARP_TWO_ARROWS_DOWN
    case doubleSharpTwoArrowsDown = "accidentalDoubleSharpTwoArrowsDown"
    /// C++: DOUBLE_FLAT_TWO_ARROWS_UP
    case doubleFlatTwoArrowsUp = "accidentalDoubleFlatTwoArrowsUp"
    /// C++: FLAT_TWO_ARROWS_UP
    case flatTwoArrowsUp = "accidentalFlatTwoArrowsUp"
    /// C++: NATURAL_TWO_ARROWS_UP
    case naturalTwoArrowsUp = "accidentalNaturalTwoArrowsUp"
    /// C++: SHARP_TWO_ARROWS_UP
    case sharpTwoArrowsUp = "accidentalSharpTwoArrowsUp"
    /// C++: DOUBLE_SHARP_TWO_ARROWS_UP
    case doubleSharpTwoArrowsUp = "accidentalDoubleSharpTwoArrowsUp"
    /// C++: DOUBLE_FLAT_THREE_ARROWS_DOWN
    case doubleFlatThreeArrowsDown = "accidentalDoubleFlatThreeArrowsDown"
    /// C++: FLAT_THREE_ARROWS_DOWN
    case flatThreeArrowsDown = "accidentalFlatThreeArrowsDown"
    /// C++: NATURAL_THREE_ARROWS_DOWN
    case naturalThreeArrowsDown = "accidentalNaturalThreeArrowsDown"
    /// C++: SHARP_THREE_ARROWS_DOWN
    case sharpThreeArrowsDown = "accidentalSharpThreeArrowsDown"
    /// C++: DOUBLE_SHARP_THREE_ARROWS_DOWN
    case doubleSharpThreeArrowsDown = "accidentalDoubleSharpThreeArrowsDown"
    /// C++: DOUBLE_FLAT_THREE_ARROWS_UP
    case doubleFlatThreeArrowsUp = "accidentalDoubleFlatThreeArrowsUp"
    /// C++: FLAT_THREE_ARROWS_UP
    case flatThreeArrowsUp = "accidentalFlatThreeArrowsUp"
    /// C++: NATURAL_THREE_ARROWS_UP
    case naturalThreeArrowsUp = "accidentalNaturalThreeArrowsUp"
    /// C++: SHARP_THREE_ARROWS_UP
    case sharpThreeArrowsUp = "accidentalSharpThreeArrowsUp"
    /// C++: DOUBLE_SHARP_THREE_ARROWS_UP
    case doubleSharpThreeArrowsUp = "accidentalDoubleSharpThreeArrowsUp"

    // MARK: — HE septimal / undecimal / tridecimal commas

    /// C++: LOWER_ONE_SEPTIMAL_COMMA
    case lowerOneSeptimalComma = "accidentalLowerOneSeptimalComma"
    /// C++: RAISE_ONE_SEPTIMAL_COMMA
    case raiseOneSeptimalComma = "accidentalRaiseOneSeptimalComma"
    /// C++: LOWER_TWO_SEPTIMAL_COMMAS
    case lowerTwoSeptimalCommas = "accidentalLowerTwoSeptimalCommas"
    /// C++: RAISE_TWO_SEPTIMAL_COMMAS
    case raiseTwoSeptimalCommas = "accidentalRaiseTwoSeptimalCommas"
    /// C++: LOWER_ONE_UNDECIMAL_QUARTERTONE
    case lowerOneUndecimalQuartertone = "accidentalLowerOneUndecimalQuartertone"
    /// C++: RAISE_ONE_UNDECIMAL_QUARTERTONE
    case raiseOneUndecimalQuartertone = "accidentalRaiseOneUndecimalQuartertone"
    /// C++: LOWER_ONE_TRIDECIMAL_QUARTERTONE
    case lowerOneTridecimalQuartertone = "accidentalLowerOneTridecimalQuartertone"
    /// C++: RAISE_ONE_TRIDECIMAL_QUARTERTONE
    case raiseOneTridecimalQuartertone = "accidentalRaiseOneTridecimalQuartertone"

    // MARK: — Equal-tempered

    /// C++: DOUBLE_FLAT_EQUAL_TEMPERED
    case doubleFlatEqualTempered = "accidentalDoubleFlatEqualTempered"
    /// C++: FLAT_EQUAL_TEMPERED
    case flatEqualTempered = "accidentalFlatEqualTempered"
    /// C++: NATURAL_EQUAL_TEMPERED
    case naturalEqualTempered = "accidentalNaturalEqualTempered"
    /// C++: SHARP_EQUAL_TEMPERED
    case sharpEqualTempered = "accidentalSharpEqualTempered"
    /// C++: DOUBLE_SHARP_EQUAL_TEMPERED
    case doubleSharpEqualTempered = "accidentalDoubleSharpEqualTempered"
    /// C++: QUARTER_FLAT_EQUAL_TEMPERED
    case quarterFlatEqualTempered = "accidentalQuarterFlatEqualTempered"
    /// C++: QUARTER_SHARP_EQUAL_TEMPERED
    case quarterSharpEqualTempered = "accidentalQuarterSharpEqualTempered"

    // MARK: — HE schisma / comma combining marks

    /// C++: FLAT_17
    case flat17 = "accidentalCombiningLower17Schisma"
    /// C++: SHARP_17
    case sharp17 = "accidentalCombiningRaise17Schisma"
    /// C++: FLAT_19
    case flat19 = "accidentalCombiningLower19Schisma"
    /// C++: SHARP_19
    case sharp19 = "accidentalCombiningRaise19Schisma"
    /// C++: FLAT_23
    case flat23 = "accidentalCombiningLower23Limit29LimitComma"
    /// C++: SHARP_23
    case sharp23 = "accidentalCombiningRaise23Limit29LimitComma"
    /// C++: FLAT_31
    case flat31 = "accidentalCombiningLower31Schisma"
    /// C++: SHARP_31
    case sharp31 = "accidentalCombiningRaise31Schisma"
    /// C++: FLAT_53
    case flat53 = "accidentalCombiningLower53LimitComma"
    /// C++: SHARP_53
    case sharp53 = "accidentalCombiningRaise53LimitComma"
    /// C++: EQUALS_ALMOST
    case enharmonicAlmostEqualTo = "accidentalEnharmonicAlmostEqualTo"
    /// C++: EQUALS
    case enharmonicEquals = "accidentalEnharmonicEquals"
    /// C++: TILDE
    case enharmonicTilde = "accidentalEnharmonicTilde"

    // MARK: — Persian

    /// C++: SORI (quarter-tone sharp)
    case sori = "accidentalSori"
    /// C++: KORON (quarter-tone flat)
    case koron = "accidentalKoron"

    // MARK: — Wyschnegradsky

    /// C++: TEN_TWELFTH_FLAT
    case tenTwelfthFlat = "accidentalWyschnegradsky10TwelfthsFlat"
    /// C++: TEN_TWELFTH_SHARP
    case tenTwelfthSharp = "accidentalWyschnegradsky10TwelfthsSharp"
    /// C++: ELEVEN_TWELFTH_FLAT
    case elevenTwelfthFlat = "accidentalWyschnegradsky11TwelfthsFlat"
    /// C++: ELEVEN_TWELFTH_SHARP
    case elevenTwelfthSharp = "accidentalWyschnegradsky11TwelfthsSharp"
    /// C++: ONE_TWELFTH_FLAT
    case oneTwelfthFlat = "accidentalWyschnegradsky1TwelfthsFlat"
    /// C++: ONE_TWELFTH_SHARP
    case oneTwelfthSharp = "accidentalWyschnegradsky1TwelfthsSharp"
    /// C++: TWO_TWELFTH_FLAT
    case twoTwelfthFlat = "accidentalWyschnegradsky2TwelfthsFlat"
    /// C++: TWO_TWELFTH_SHARP
    case twoTwelfthSharp = "accidentalWyschnegradsky2TwelfthsSharp"
    /// C++: THREE_TWELFTH_FLAT
    case threeTwelfthFlat = "accidentalWyschnegradsky3TwelfthsFlat"
    /// C++: THREE_TWELFTH_SHARP
    case threeTwelfthSharp = "accidentalWyschnegradsky3TwelfthsSharp"
    /// C++: FOUR_TWELFTH_FLAT
    case fourTwelfthFlat = "accidentalWyschnegradsky4TwelfthsFlat"
    /// C++: FOUR_TWELFTH_SHARP
    case fourTwelfthSharp = "accidentalWyschnegradsky4TwelfthsSharp"
    /// C++: FIVE_TWELFTH_FLAT
    case fiveTwelfthFlat = "accidentalWyschnegradsky5TwelfthsFlat"
    /// C++: FIVE_TWELFTH_SHARP
    case fiveTwelfthSharp = "accidentalWyschnegradsky5TwelfthsSharp"
    /// C++: SIX_TWELFTH_FLAT
    case sixTwelfthFlat = "accidentalWyschnegradsky6TwelfthsFlat"
    /// C++: SIX_TWELFTH_SHARP
    case sixTwelfthSharp = "accidentalWyschnegradsky6TwelfthsSharp"
    /// C++: SEVEN_TWELFTH_FLAT
    case sevenTwelfthFlat = "accidentalWyschnegradsky7TwelfthsFlat"
    /// C++: SEVEN_TWELFTH_SHARP
    case sevenTwelfthSharp = "accidentalWyschnegradsky7TwelfthsSharp"
    /// C++: EIGHT_TWELFTH_FLAT
    case eightTwelfthFlat = "accidentalWyschnegradsky8TwelfthsFlat"
    /// C++: EIGHT_TWELFTH_SHARP
    case eightTwelfthSharp = "accidentalWyschnegradsky8TwelfthsSharp"
    /// C++: NINE_TWELFTH_FLAT
    case nineTwelfthFlat = "accidentalWyschnegradsky9TwelfthsFlat"
    /// C++: NINE_TWELFTH_SHARP
    case nineTwelfthSharp = "accidentalWyschnegradsky9TwelfthsSharp"

    // MARK: — Sagittal (Spartan subset)

    /// C++: SAGITTAL_5V7KD
    case sagittal5v7KleismaDown = "accSagittal5v7KleismaDown"
    /// C++: SAGITTAL_5V7KU
    case sagittal5v7KleismaUp = "accSagittal5v7KleismaUp"
    /// C++: SAGITTAL_5CD
    case sagittal5CommaDown = "accSagittal5CommaDown"
    /// C++: SAGITTAL_5CU
    case sagittal5CommaUp = "accSagittal5CommaUp"
    /// C++: SAGITTAL_7CD
    case sagittal7CommaDown = "accSagittal7CommaDown"
    /// C++: SAGITTAL_7CU
    case sagittal7CommaUp = "accSagittal7CommaUp"
    /// C++: SAGITTAL_25SDD
    case sagittal25SmallDiesisDown = "accSagittal25SmallDiesisDown"
    /// C++: SAGITTAL_25SDU
    case sagittal25SmallDiesisUp = "accSagittal25SmallDiesisUp"
    /// C++: SAGITTAL_35MDD
    case sagittal35MediumDiesisDown = "accSagittal35MediumDiesisDown"
    /// C++: SAGITTAL_35MDU
    case sagittal35MediumDiesisUp = "accSagittal35MediumDiesisUp"
    /// C++: SAGITTAL_11MDD
    case sagittal11MediumDiesisDown = "accSagittal11MediumDiesisDown"
    /// C++: SAGITTAL_11MDU
    case sagittal11MediumDiesisUp = "accSagittal11MediumDiesisUp"
    /// C++: SAGITTAL_11LDD
    case sagittal11LargeDiesisDown = "accSagittal11LargeDiesisDown"
    /// C++: SAGITTAL_11LDU
    case sagittal11LargeDiesisUp = "accSagittal11LargeDiesisUp"
    /// C++: SAGITTAL_35LDD
    case sagittal35LargeDiesisDown = "accSagittal35LargeDiesisDown"
    /// C++: SAGITTAL_35LDU
    case sagittal35LargeDiesisUp = "accSagittal35LargeDiesisUp"
    /// C++: SAGITTAL_FLAT25SU
    case sagittalFlat25SUp = "accSagittalFlat25SUp"
    /// C++: SAGITTAL_SHARP25SD
    case sagittalSharp25SDown = "accSagittalSharp25SDown"
    /// C++: SAGITTAL_FLAT7CU
    case sagittalFlat7CUp = "accSagittalFlat7CUp"
    /// C++: SAGITTAL_SHARP7CD
    case sagittalSharp7CDown = "accSagittalSharp7CDown"
    /// C++: SAGITTAL_FLAT5CU
    case sagittalFlat5CUp = "accSagittalFlat5CUp"
    /// C++: SAGITTAL_SHARP5CD
    case sagittalSharp5CDown = "accSagittalSharp5CDown"
    /// C++: SAGITTAL_FLAT5V7KU
    case sagittalFlat5v7kUp = "accSagittalFlat5v7kUp"
    /// C++: SAGITTAL_SHARP5V7KD
    case sagittalSharp5v7kDown = "accSagittalSharp5v7kDown"
    /// C++: SAGITTAL_FLAT
    case sagittalFlat = "accSagittalFlat"
    /// C++: SAGITTAL_SHARP
    case sagittalSharp = "accSagittalSharp"

    // MARK: — Turkish folk music

    /// C++: ONE_COMMA_FLAT
    case oneCommaFlat = "accidental1CommaFlat"
    /// C++: ONE_COMMA_SHARP
    case oneCommaSharp = "accidental1CommaSharp"
    /// C++: TWO_COMMA_FLAT
    case twoCommaFlat = "accidental2CommaFlat"
    /// C++: TWO_COMMA_SHARP
    case twoCommaSharp = "accidental2CommaSharp"
    /// C++: THREE_COMMA_FLAT
    case threeCommaFlat = "accidental3CommaFlat"
    /// C++: THREE_COMMA_SHARP
    case threeCommaSharp = "accidental3CommaSharp"
    /// C++: FOUR_COMMA_FLAT
    case fourCommaFlat = "accidental4CommaFlat"
    // C++: FOUR_COMMA_SHARP is commented out in MuseScore source — omitted.
    /// C++: FIVE_COMMA_SHARP
    case fiveCommaSharp = "accidental5CommaSharp"
}

extension Accidental {
    /// Decode from MSCX `<Accidental><subtype>` text value.
    /// Returns `nil` for unrecognized tokens.
    public init?(mscxSubtype: String) {
        self.init(rawValue: mscxSubtype)
    }

    /// MSCX `<Accidental><subtype>` text value (= the SMuFL SymId name).
    public var mscxSubtype: String {
        rawValue
    }
}

// MARK: — AccidentalBracket

/// Visual bracket drawn around a note accidental.
/// C++: `mu::engraving::AccidentalBracket` (`src/engraving/dom/accidental.h`)
public enum AccidentalBracket: Int, Sendable {
    case none = 0
    case parenthesis = 1
    case bracket = 2
}
