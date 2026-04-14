import Foundation

/// Visual accidental on a note. Display-only; MIDI pitch is the source of truth.
/// C++: `mu::engraving::AccidentalType` (subset)
public enum Accidental: String, Sendable {
    case sharp, flat, natural, doubleSharp, doubleFlat

    /// Decode from mscx `<Accidental><subtype>` text values.
    public init?(mscxSubtype: String) {
        switch mscxSubtype {
        case "accidentalSharp":       self = .sharp
        case "accidentalFlat":        self = .flat
        case "accidentalNatural":     self = .natural
        case "accidentalDoubleSharp": self = .doubleSharp
        case "accidentalDoubleFlat":  self = .doubleFlat
        default:                      return nil
        }
    }
}
