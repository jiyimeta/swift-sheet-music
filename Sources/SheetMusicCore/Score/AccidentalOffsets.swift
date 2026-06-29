import Foundation

extension Accidental {
    /// Semitone shift from the natural pitch of the same diatonic letter.
    ///
    /// Standard accidentals carry their exact value; microtonal accidentals
    /// return the integer part only (0 for true quarter-tones, ±1 for
    /// three-quarter-tones, etc.). This is sufficient for pitch-respelling
    /// purposes — display rendering uses the glyph, not this value.
    ///
    /// C++: `AccidentalVal` integer fields in `ACC_LIST[]`
    ///      (`src/engraving/dom/accidental.cpp:51-224`).
    public var semitoneOffset: Int {
        switch self {
        case .tripleFlat: -3
        case .doubleFlat: -2
        case .flat, .naturalFlat: -1
        case .natural: 0
        case .sharp, .naturalSharp: 1
        case .doubleSharp, .sharpSharp: 2
        case .tripleSharp: 3
        default: 0 // microtonal → integer part
        }
    }
}
