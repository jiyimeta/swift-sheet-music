import CoreGraphics

/// Bravura / SMuFL Private Use Area codepoints for the glyphs we draw.
/// Values are the SMuFL standard: https://www.smufl.org/
enum SMuFLGlyph {
    // Clefs
    static let gClef: Character = "\u{E050}"
    static let gClef15mb: Character = "\u{E051}"
    static let gClef8vb: Character = "\u{E052}"
    static let gClef8va: Character = "\u{E053}"
    static let gClef15ma: Character = "\u{E054}"
    static let fClef: Character = "\u{E062}"
    static let fClef15mb: Character = "\u{E063}"
    static let fClef8vb: Character = "\u{E064}"
    static let fClef8va: Character = "\u{E065}"
    static let cClef: Character = "\u{E05C}"
    static let percussionClef: Character = "\u{E069}"

    // Noteheads — standard
    static let noteheadWhole: Character = "\u{E0A2}"
    static let noteheadHalf: Character = "\u{E0A3}"
    static let noteheadBlack: Character = "\u{E0A4}"
    // Noteheads — cross (x). Per the SMuFL Noteheads range
    // (U+E0A0..U+E0FF), the X family lives at U+E0A6..U+E0A9; the
    // earlier `U+E0AA`/`U+E0AB` codepoints were actually the
    // `noteheadPlusDoubleWhole` / `noteheadPlusWhole` glyphs (the
    // plus-in-a-circle shapes), which is why whole-note crosses
    // were rendering as "double sharp + 丸".
    static let noteheadXDoubleWhole: Character = "\u{E0A6}"
    static let noteheadXWhole: Character = "\u{E0A7}"
    static let noteheadXHalf: Character = "\u{E0A8}"
    static let noteheadXBlack: Character = "\u{E0A9}"
    // Noteheads — diamond
    static let noteheadDiamondWhole: Character = "\u{E0D8}"
    static let noteheadDiamondHalf: Character = "\u{E0D9}"
    static let noteheadDiamondBlack: Character = "\u{E0DB}"
    // Noteheads — triangle
    static let noteheadTriangleUpBlack: Character = "\u{E0BE}"
    static let noteheadTriangleDownBlack: Character = "\u{E0C7}"

    // Flags
    static let flag8thUp: Character = "\u{E240}"
    static let flag8thDown: Character = "\u{E241}"
    static let flag16thUp: Character = "\u{E242}"
    static let flag16thDown: Character = "\u{E243}"
    static let flag32ndUp: Character = "\u{E244}"
    static let flag32ndDown: Character = "\u{E245}"
    static let flag64thUp: Character = "\u{E246}"
    static let flag64thDown: Character = "\u{E247}"

    // Rests
    static let restWhole: Character = "\u{E4E3}"
    static let restHalf: Character = "\u{E4E4}"
    // Whole / half rest variants with a baked-in leger line —
    // used when the rest is hung above or below the staff (e.g.
    // voice-2 whole rests in a multi-voice measure). MuseScore
    // swaps to these via `Rest::getSymbol` when `line` is outside
    // the staff range (`rest.cpp:260-262`). Codepoints from
    // SMuFL's `glyphnames.json`: `restWholeLegerLine` is U+E4F4
    // and `restHalfLegerLine` is U+E4F5 (the earlier U+E4F3 was
    // `restHBar`, the multi-measure I-beam, hence the wrong glyph).
    static let restWholeLegerLine: Character = "\u{E4F4}"
    static let restHalfLegerLine: Character = "\u{E4F5}"
    static let restQuarter: Character = "\u{E4E5}"
    static let rest8th: Character = "\u{E4E6}"
    static let rest16th: Character = "\u{E4E7}"
    static let rest32nd: Character = "\u{E4E8}"
    static let rest64th: Character = "\u{E4E9}"

    // Accidentals
    static let accidentalSharp: Character = "\u{E262}"
    static let accidentalFlat: Character = "\u{E260}"
    static let accidentalNatural: Character = "\u{E261}"
    static let accidentalDoubleSharp: Character = "\u{E263}"
    static let accidentalDoubleFlat: Character = "\u{E264}"

    // Time signature digits (0..9)
    static func timeSigDigit(_ d: Int) -> Character {
        // 0xE080..0xE089 are private-use SMuFL digits — always valid scalars.
        // swiftlint:disable:next force_unwrapping
        Character(UnicodeScalar(0xE080 + max(0, min(9, d)))!)
    }

    static let timeSigCommon: Character = "\u{E08A}"
    static let timeSigCutCommon: Character = "\u{E08B}"

    // Segno / Coda / Fermata (used later stages)
    static let segno: Character = "\u{E047}"
    static let coda: Character = "\u{E048}"
    static let fermataAbove: Character = "\u{E4C0}"
    static let fermataBelow: Character = "\u{E4C1}"

    // Articulations — SMuFL Articulation range (U+E4A0..U+E4BF).
    // Above/below pairs render the same shape mirrored across the
    // baseline; MuseScore picks the variant from the articulation's
    // resolved anchor side. Codepoints from SMuFL `glyphnames.json`.
    static let articStaccatoAbove: Character = "\u{E4A2}"
    static let articStaccatoBelow: Character = "\u{E4A3}"
    static let articTenutoAbove: Character = "\u{E4A4}"
    static let articTenutoBelow: Character = "\u{E4A5}"
    static let articStaccatissimoAbove: Character = "\u{E4A6}"
    static let articStaccatissimoBelow: Character = "\u{E4A7}"
    static let articAccentAbove: Character = "\u{E4A0}"
    static let articAccentBelow: Character = "\u{E4A1}"
    static let articMarcatoAbove: Character = "\u{E4AC}"
    static let articMarcatoBelow: Character = "\u{E4AD}"
    static let articAccentStaccatoAbove: Character = "\u{E4B0}"
    static let articAccentStaccatoBelow: Character = "\u{E4B1}"
    static let articMarcatoStaccatoAbove: Character = "\u{E4AE}"
    static let articMarcatoStaccatoBelow: Character = "\u{E4AF}"

    // Bracket caps + brace variants. The brace family lives in
    // Bravura's PUA optionalGlyphs range — MuseScore picks one of
    // four per number of spanned staves (`engraving/dom/bracket.cpp::
    // computeMagx`):
    //   v=1 → braceSmall, v=2 → brace, v=3 → braceLarge, v≥4 → braceLarger.
    static let brace: Character = "\u{E000}"
    static let braceSmall: Character = "\u{F400}"
    static let braceLarge: Character = "\u{F401}"
    static let braceLarger: Character = "\u{F402}"
    static let bracketTop: Character = "\u{E003}"
    static let bracketBottom: Character = "\u{E004}"

    /// Pick the brace SMuFL codepoint and the X-magnification factor
    /// for a given staff span, matching MuseScore's
    /// `Bracket::computeMagx`. Returns `(codepoint, magx)`.
    static func braceVariant(staffCount: Int) -> (UInt16, CGFloat) {
        let v = max(staffCount, 1)
        let magx: CGFloat = v == 1
            ? 1
            : CGFloat(v) + CGFloat(v - 1) * 1.625
        switch v {
        case 1: return (0xF400, magx) // braceSmall
        case 2: return (0xE000, magx) // brace
        case 3: return (0xF401, magx) // braceLarge
        default: return (0xF402, magx) // braceLarger (v ≥ 4)
        }
    }

    // Keyboard pedal — SMuFL Keyboard Techniques range
    // (U+E650..U+E67F). MuseScore renders pedal lines using these
    // glyphs from the music font, not text. The "Ped." mark and
    // the closing "*" both carry the bold serif weight that makes
    // them visually distinct from prose text.
    static let keyboardPedalPed: Character = "\u{E650}"
    static let keyboardPedalUp: Character = "\u{E655}"

    // Dynamics — atomic letter glyphs from SMuFL Dynamics range
    // (U+E520..U+E526). MuseScore composes multi-letter dynamics
    // (mp, mf, ff, fff, …) from these per `dynamic.cpp` DYN_LIST.
    // The bold serif weight is part of the *music font* (Bravura);
    // hence dynamics look much heavier than Edwin italic text.
    static let dynamicPiano: Character = "\u{E520}"
    static let dynamicMezzo: Character = "\u{E521}"
    static let dynamicForte: Character = "\u{E522}"
    static let dynamicRinforzando: Character = "\u{E523}"
    static let dynamicSforzando: Character = "\u{E524}"
    static let dynamicZ: Character = "\u{E525}"
    static let dynamicNiente: Character = "\u{E526}"

    // Arpeggio / measure repeat (used later stages)
    static let arpeggioWiggle: Character = "\u{EAA9}"
    static let arpeggioUpArrow: Character = "\u{EAAD}"
    static let arpeggioDownArrow: Character = "\u{EAAE}"
    static let repeat1Bar: Character = "\u{E500}"
    static let repeat2Bars: Character = "\u{E501}"
    static let repeat4Bars: Character = "\u{E502}"
}
