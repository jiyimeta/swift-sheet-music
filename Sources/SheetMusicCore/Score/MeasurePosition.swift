import Foundation

/// Offset within a measure, measured as a fraction of a whole note
/// from the measure's start. `0/4` is the downbeat; `1/4` is the
/// end of beat 1 in 4/4; `1/8` is the "and" of beat 1 in 4/4.
///
/// Distinct nominal type from `Fraction` so positions don't get
/// mixed with durations at API boundaries. MuseScore 4 allows
/// system markings (tempo, rehearsal marks, system text, swing)
/// at half-beat resolution even where no chord/rest is present at
/// that tick — this type is the representation that survives that.
///
/// C++: `mu::engraving::Fraction` used as a relative tick offset
/// inside `Segment::rtick()`.
public struct MeasurePosition: Hashable, Sendable {
    public let offset: Fraction

    public init(offset: Fraction) {
        self.offset = offset
    }

    public init(numerator: Int, denominator: Int) {
        offset = Fraction(numerator: numerator, denominator: denominator)
    }

    /// Start of the measure (downbeat).
    public static let start = MeasurePosition(numerator: 0, denominator: 4)

    /// Number of MIDI ticks from the measure start at the given PPQ.
    public func ticks(division: Int) -> Int {
        offset.ticks(division: division)
    }
}

extension MeasurePosition: Comparable {
    public static func < (lhs: MeasurePosition, rhs: MeasurePosition) -> Bool {
        lhs.offset.numerator * rhs.offset.denominator
            < rhs.offset.numerator * lhs.offset.denominator
    }
}
