import SheetMusicFoundation

/// Standard note duration. C++: `mu::engraving::TDuration` (subset).
/// `.fraction` covers irregular durations encoded as raw fractions
/// (e.g. tuplet-scaled members written `<duration>1/12</duration>`).
/// `.measure` is a marker for "this rest fills the containing
/// measure" — it carries no intrinsic duration; consumers must call
/// `resolved(in:)` against the measure's effective duration before
/// asking for ticks or a Fraction. Mirrors MuseScore's
/// `DurationType::V_MEASURE` and MusicXML's `<rest measure="yes"/>`.
public enum NoteDuration: Sendable, Equatable, Hashable {
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
    case measure

    /// Number of MIDI ticks at a given PPQ division. quarter = 1 * division.
    /// Traps on `.measure` — call `resolved(in:)` first.
    public func ticks(division: Int) -> Int {
        switch self {
        case .whole: return 4 * division
        case .half: return 2 * division
        case .quarter: return division
        case .eighth: return division / 2
        case .sixteenth: return division / 4
        case .thirtySecond: return division / 8
        case .sixtyFourth: return division / 16
        case .oneTwentyEighth: return division / 32
        case .twoFiftySixth: return division / 64
        case let .fraction(f): return f.ticks(division: division)
        case .measure:
            preconditionFailure(
                ".measure has no fixed tick count; "
                    + "resolve via resolved(in:) first",
            )
        }
    }

    /// Decode from MuseScore mscx `<durationType>` text values.
    /// Returns nil for "measure" — callers parse the parent element
    /// to decide between `.measure` and a typed rest.
    public init?(mscxName: String) {
        switch mscxName {
        case "whole": self = .whole
        case "half": self = .half
        case "quarter": self = .quarter
        case "eighth": self = .eighth
        case "16th": self = .sixteenth
        case "32nd": self = .thirtySecond
        case "64th": self = .sixtyFourth
        case "128th": self = .oneTwentyEighth
        case "256th": self = .twoFiftySixth
        default: return nil
        }
    }

    /// This duration expressed as a fraction of a whole note. Traps
    /// on `.measure` — call `resolved(in:)` first.
    public var asFraction: Fraction {
        switch self {
        case .whole: return Fraction(numerator: 1, denominator: 1)
        case .half: return Fraction(numerator: 1, denominator: 2)
        case .quarter: return Fraction(numerator: 1, denominator: 4)
        case .eighth: return Fraction(numerator: 1, denominator: 8)
        case .sixteenth: return Fraction(numerator: 1, denominator: 16)
        case .thirtySecond: return Fraction(numerator: 1, denominator: 32)
        case .sixtyFourth: return Fraction(numerator: 1, denominator: 64)
        case .oneTwentyEighth: return Fraction(numerator: 1, denominator: 128)
        case .twoFiftySixth: return Fraction(numerator: 1, denominator: 256)
        case let .fraction(f): return f
        case .measure:
            preconditionFailure(
                ".measure has no fixed duration; "
                    + "resolve via resolved(in:) first",
            )
        }
    }

    /// Apply augmentation dots: each dot extends the duration by half
    /// of the prior length (1 dot = 1.5x, 2 dots = 1.75x, …). Returns
    /// a `.fraction` with the result. Traps on `.measure` — augmenting
    /// a measure-rest marker has no musical meaning.
    public func dotted(_ dots: Int) -> NoteDuration {
        precondition(dots >= 0, "dots must be non-negative")
        if dots == 0 { return self }
        if case .measure = self {
            preconditionFailure(
                ".measure cannot be augmented with dots",
            )
        }
        let base = asFraction
        let factorNumerator = (1 << (dots + 1)) - 1
        let factorDenominator = 1 << dots
        let n = base.numerator * factorNumerator
        let d = base.denominator * factorDenominator
        return .fraction(Fraction(numerator: n, denominator: d))
    }

    /// Split this duration into the base and dot count `dotted(_:)` would produce it from, or `nil` when no such
    /// pair exists. The exact inverse of `dotted(_:)`, and the decomposition `SetDots` needs: a host asking for
    /// "two dots" is asking for `base.dotted(2)`, and `base` is whatever the slot is spelled with today.
    ///
    /// An undotted case answers `(self, 0)`. `.measure` answers `nil` — it has no intrinsic length to dot, and
    /// `asFraction` traps on it, so the guard comes first. A `.fraction` answers only when it equals some
    /// `base.dotted(dots)`: a tuplet-scaled member (`1/12`) and any other irregular value answer `nil`, which is
    /// what `SetDots` turns into `.notDottable`.
    ///
    /// Dots are searched to three, the ceiling MuseScore's palette offers; its own decomposition
    /// (`durationtype.cpp:85-109`) instead finds the largest type that FITS and truncates, which is right for
    /// re-spelling an arbitrary tick count and wrong here — this must be lossless, because the value it decomposes
    /// is one this model wrote.
    public func baseAndDots() -> (base: NoteDuration, dots: Int)? {
        if case .measure = self { return nil }
        let bases: [NoteDuration] = [
            .whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond, .sixtyFourth,
            .oneTwentyEighth, .twoFiftySixth,
        ]
        if let plain = bases.first(where: { $0 == self }) {
            return (base: plain, dots: 0)
        }
        let target = asFraction
        for base in bases {
            for dots in 1 ... 3 where base.dotted(dots).asFraction == target {
                return (base: base, dots: dots)
            }
        }
        return nil
    }
}
