/// Bravura / SMuFL Private Use Area codepoints for the glyphs we draw.
/// Values are the SMuFL standard: https://www.smufl.org/
@available(macOS 15.0, iOS 16.0, *)
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

    // Arpeggio / measure repeat (used later stages)
    static let arpeggioWiggle: Character = "\u{EAA9}"
    static let arpeggioUpArrow: Character = "\u{EAAD}"
    static let arpeggioDownArrow: Character = "\u{EAAE}"
    static let repeat1Bar: Character = "\u{E500}"
    static let repeat2Bars: Character = "\u{E501}"
    static let repeat4Bars: Character = "\u{E502}"
}
