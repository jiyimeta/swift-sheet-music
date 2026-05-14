import Foundation

/// A rational number used for note durations and time positions.
/// C++: `mu::engraving::Fraction`
public struct Fraction: Hashable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public init(numerator: Int, denominator: Int) {
        precondition(denominator > 0, "Fraction denominator must be positive")
        let g = Self.gcd(abs(numerator), denominator)
        self.numerator = numerator / g
        self.denominator = denominator / g
    }

    /// Decode from a `"N/D"` string (the mscx `<duration>` form). Returns nil if malformed.
    public init?(mscxString: String) {
        let parts = mscxString.split(separator: "/")
        guard parts.count == 2,
              let n = Int(parts[0]),
              let d = Int(parts[1]),
              d > 0 else { return nil }
        self.init(numerator: n, denominator: d)
    }

    /// Number of MIDI ticks this fraction-of-a-whole-note represents at the given PPQ division.
    /// A whole note = 4 quarter notes = 4 * division ticks.
    public func ticks(division: Int) -> Int {
        numerator * 4 * division / denominator
    }

    public static func + (lhs: Fraction, rhs: Fraction) -> Fraction {
        let d = lhs.denominator * rhs.denominator
        let n = lhs.numerator * rhs.denominator + rhs.numerator * lhs.denominator
        return Fraction(numerator: n, denominator: d)
    }

    public static func - (lhs: Fraction, rhs: Fraction) -> Fraction {
        let d = lhs.denominator * rhs.denominator
        let n = lhs.numerator * rhs.denominator - rhs.numerator * lhs.denominator
        return Fraction(numerator: n, denominator: d)
    }

    public static func += (lhs: inout Fraction, rhs: Fraction) {
        lhs = lhs + rhs
    }

    public static func -= (lhs: inout Fraction, rhs: Fraction) {
        lhs = lhs - rhs
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return a == 0 ? 1 : a
    }
}
