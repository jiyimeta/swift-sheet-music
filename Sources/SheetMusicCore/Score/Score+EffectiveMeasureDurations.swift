import Foundation

extension [Measure] {
    /// Effective duration of each measure, indexed by position in the
    /// array. Equals the measure's `actualLength` when set, otherwise
    /// the prevailing `TimeSignature` carried forward from earlier
    /// measures. Defaults to 4/4 when no time signature has appeared yet.
    ///
    /// Call sites: encoders, renderers, tick walkers that need to resolve
    /// `.measure` durations against the containing bar.
    public func effectiveMeasureDurations() -> [Fraction] {
        var prevailing = Fraction(numerator: 4, denominator: 4)
        var result: [Fraction] = []
        result.reserveCapacity(count)
        for measure in self {
            for el in measure.voices.flatMap(\.elements) {
                if case let .timeSignature(ts) = el {
                    prevailing = Fraction(
                        numerator: ts.numerator,
                        denominator: ts.denominator,
                    )
                    // The first time signature in a measure governs
                    // that measure; later ones (rare) still carry
                    // forward to subsequent measures.
                    break
                }
            }
            result.append(measure.actualLength ?? prevailing)
        }
        return result
    }
}

extension Score {
    /// Effective duration of each measure across the score, indexed
    /// by measure number. Equals the measure's `actualLength` when
    /// set, otherwise the prevailing `TimeSignature` (numerator /
    /// denominator) carried forward from earlier voice elements.
    /// Defaults to 4/4 when no time signature has appeared yet.
    ///
    /// TimeSignature changes are score-wide in this model, so reading
    /// from a single (part, staff) is sufficient. The first part /
    /// first staff is the default.
    ///
    /// Used by encoders / renderers / tick walkers that need to
    /// resolve `.measure` durations against the containing bar.
    public func effectiveMeasureDurations(
        partIndex: Int = 0,
        staffIndex: Int = 0,
    ) -> [Fraction] {
        guard partIndex < parts.count,
              staffIndex < parts[partIndex].staves.count
        else { return [] }
        return parts[partIndex].staves[staffIndex].measures
            .effectiveMeasureDurations()
    }
}
