import Foundation

/// Standard note duration. C++: `mu::engraving::TDuration` (subset).
/// `.fraction` covers full-measure rests and other irregular durations encoded as
/// `<durationType>measure</durationType>` + `<duration>N/D</duration>` in mscx.
public enum NoteDuration: Sendable, Equatable {
    case whole
    case half
    case quarter
    case eighth
    case sixteenth
    case thirtySecond
    case sixtyFourth
    case oneTwentyEighth
    case twoFiftySixth
    case fraction(Fraction)

    /// Number of MIDI ticks at a given PPQ division. quarter = 1 * division.
    public func ticks(division: Int) -> Int {
        switch self {
        case .whole:           return 4 * division
        case .half:            return 2 * division
        case .quarter:         return division
        case .eighth:          return division / 2
        case .sixteenth:       return division / 4
        case .thirtySecond:    return division / 8
        case .sixtyFourth:     return division / 16
        case .oneTwentyEighth: return division / 32
        case .twoFiftySixth:   return division / 64
        case let .fraction(f): return f.ticks(division: division)
        }
    }

    /// Decode from MuseScore mscx `<durationType>` text values.
    /// Returns nil for "measure" — callers must use `<duration>` to build a `.fraction`.
    public init?(mscxName: String) {
        switch mscxName {
        case "whole":   self = .whole
        case "half":    self = .half
        case "quarter": self = .quarter
        case "eighth":  self = .eighth
        case "16th":    self = .sixteenth
        case "32nd":    self = .thirtySecond
        case "64th":    self = .sixtyFourth
        case "128th":   self = .oneTwentyEighth
        case "256th":   self = .twoFiftySixth
        default:        return nil
        }
    }

    /// Apply augmentation dots: each dot extends the duration by half of the prior length
    /// (1 dot = 1.5x, 2 dots = 1.75x, etc.). Returns a `.fraction` with the result.
    public func dotted(_ dots: Int) -> NoteDuration {
        precondition(dots >= 0, "dots must be non-negative")
        if dots == 0 { return self }
        // Express base as a fraction of a whole note, then multiply by (2^(d+1) - 1) / 2^d.
        let base: Fraction
        switch self {
        case .whole:        base = Fraction(numerator: 1, denominator: 1)
        case .half:         base = Fraction(numerator: 1, denominator: 2)
        case .quarter:      base = Fraction(numerator: 1, denominator: 4)
        case .eighth:       base = Fraction(numerator: 1, denominator: 8)
        case .sixteenth:    base = Fraction(numerator: 1, denominator: 16)
        case .thirtySecond: base = Fraction(numerator: 1, denominator: 32)
        case .sixtyFourth:  base = Fraction(numerator: 1, denominator: 64)
        case .oneTwentyEighth: base = Fraction(numerator: 1, denominator: 128)
        case .twoFiftySixth:   base = Fraction(numerator: 1, denominator: 256)
        case let .fraction(f): base = f
        }
        let factorNumerator = (1 << (dots + 1)) - 1
        let factorDenominator = 1 << dots
        let n = base.numerator * factorNumerator
        let d = base.denominator * factorDenominator
        return .fraction(Fraction(numerator: n, denominator: d))
    }
}
