import SheetMusicCore
import SheetMusicFoundation

extension Fraction {
    /// Zero, spelled once for the MusicXML walk — `Fraction` has no zero constant and no ordering of its own.
    static let zeroTick = Fraction(numerator: 0, denominator: 1)

    var isZeroTick: Bool {
        numerator == 0
    }

    /// `self < other`. Denominators are positive (`Fraction.init` preconditions it), so cross-multiplying orders them.
    func precedes(_ other: Fraction) -> Bool {
        numerator * other.denominator < other.numerator * denominator
    }
}
