import SheetMusicCore
import SheetMusicFoundation

/// SMuFL code point for a note accidental. Single source of truth so the
/// Apple renderer (`AccidentalRenderer`) and the Android bridge
/// (`LayoutBridge.accidentalCodepoint`) can't drift apart — both consume
/// this instead of keeping parallel `Accidental` switches. Mirrors the
/// `NoteheadGlyph` / `FlagGlyph` / `RestGlyph` pattern.
public enum AccidentalGlyph {
    /// Returns the SMuFL codepoint for `accidental`.
    ///
    /// `Accidental.rawValue` equals the MuseScore `<subtype>` string, which is
    /// also the SMuFL SymId name.  `SMuFLCodepoint.byName(_:)` therefore
    /// resolves every case in the 146-case enum directly.  The `?? accidentalNatural`
    /// fallback is unreachable in practice — a generator-coverage test asserts
    /// all 146 raw values resolve — but keeps the function total.
    public static func codepoint(_ accidental: Accidental) -> UInt32 {
        SMuFLCodepoint.byName(accidental.mscxSubtype) ?? SMuFLCodepoint.accidentalNatural
    }

    /// Returns the SMuFL left/right bracket glyphs for `bracket`, or `nil` for
    /// `.none`.
    ///
    /// C++: `mu::engraving::AccidentalBracket` glyph selection in
    /// `accidental.cpp` / `tlayout.cpp:553-562`.
    public static func enclosure(
        _ bracket: AccidentalBracket,
    ) -> (left: UInt32, right: UInt32)? {
        switch bracket {
        case .none:
            return nil
        case .parenthesis:
            return (SMuFLCodepoint.accidentalParensLeft, SMuFLCodepoint.accidentalParensRight)
        case .bracket:
            return (SMuFLCodepoint.accidentalBracketLeft, SMuFLCodepoint.accidentalBracketRight)
        }
    }
}
