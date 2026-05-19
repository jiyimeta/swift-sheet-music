#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Staff-step tables and spacing used when laying out a key signature.
///
/// "Step" is a half-staff-space ordinal: the middle line is 0, the
/// space above it is +1, the line above that is +2, and so on. Sharp
/// and flat key signatures use distinct, fixed step sequences chosen
/// to keep the accidental cluster tightly inside the staff.
public enum KeySignatureSteps {
    /// Treble-staff steps for each sharp in canonical engraving order
    /// (F♯, C♯, G♯, D♯, A♯, E♯, B♯). Middle line = 0, positive = up.
    public static let sharps: [Int] = [4, 1, 5, 2, -1, 3, 0]

    /// Treble-staff steps for each flat in canonical engraving order
    /// (B♭, E♭, A♭, D♭, G♭, C♭, F♭).
    public static let flats: [Int] = [0, 3, -1, 2, -2, 1, -3]

    /// Horizontal advance between consecutive accidentals. 1 sp causes
    /// visible overlap at 5+-accidental keys (sharp glyphs are ~1 sp
    /// wide but the optical side-bearing needs more breathing room);
    /// 1.4 sp matches MuseScore's defaults.
    public static func advance(sp: CGFloat) -> CGFloat {
        sp * 1.4
    }

    /// Convert a step value to a Y offset relative to the staff-middle
    /// reference Y. Positive step = up, which is `-dy` in y-down screen
    /// coordinates.
    public static func stepDy(step: Int, sp: CGFloat) -> CGFloat {
        -CGFloat(step) * sp / 2
    }
}
