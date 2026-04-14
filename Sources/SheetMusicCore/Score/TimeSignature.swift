import Foundation

/// A time signature like 4/4 or 6/8. C++: `mu::engraving::TimeSig`.
public struct TimeSignature: Sendable, Equatable {
    public var numerator: Int
    public var denominator: Int

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
}
