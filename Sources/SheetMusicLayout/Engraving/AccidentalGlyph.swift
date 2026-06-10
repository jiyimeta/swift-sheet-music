import Foundation
import SheetMusicCore

/// SMuFL code point for a note accidental. Single source of truth so the
/// Apple renderer (`AccidentalRenderer`) and the Android bridge
/// (`LayoutBridge.accidentalCodepoint`) can't drift apart — both consume
/// this instead of keeping parallel `Accidental` switches. Mirrors the
/// `NoteheadGlyph` / `FlagGlyph` / `RestGlyph` pattern.
public enum AccidentalGlyph {
    public static func codepoint(_ accidental: Accidental) -> UInt32 {
        switch accidental {
        case .sharp: SMuFLCodepoint.accidentalSharp
        case .flat: SMuFLCodepoint.accidentalFlat
        case .natural: SMuFLCodepoint.accidentalNatural
        case .doubleSharp: SMuFLCodepoint.accidentalDoubleSharp
        case .doubleFlat: SMuFLCodepoint.accidentalDoubleFlat
        }
    }
}
