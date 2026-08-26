import SheetMusicFoundation

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
            // Nested loops rather than `voices.flatMap(\.elements)`:
            // the flatMap allocated a fresh array for every measure,
            // and this function is called on whole-staff measure lists.
            outer: for voice in measure.voices {
                for el in voice.elements {
                    if case let .timeSignature(ts) = el {
                        prevailing = Fraction(
                            numerator: ts.numerator,
                            denominator: ts.denominator,
                        )
                        // The first time signature in a measure governs
                        // that measure; later ones (rare) still carry
                        // forward to subsequent measures.
                        break outer
                    }
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

    /// Effective duration of one measure on one staff — the value a
    /// `.measure` duration there resolves to.
    ///
    /// Falls back to 4/4 for an out-of-range staff or measure, matching
    /// the default the table above uses before any time signature has
    /// appeared. Reads the measure's OWN staff rather than part 0 /
    /// staff 0, because `actualLength` (unlike the time signature) is
    /// per-measure and so can differ between staves.
    ///
    /// This walks the staff's whole measure list, so call it once per
    /// edit — not once per measure of a loop. A loop wants
    /// `effectiveMeasureDurations()` and an index.
    public func effectiveMeasureDuration(
        at staff: StaffAddress, measureIndex: Int,
    ) -> Fraction {
        let durations = effectiveMeasureDurations(
            partIndex: staff.partIndex,
            staffIndex: staff.staffIndexInPart,
        )
        guard durations.indices.contains(measureIndex) else {
            return Fraction(numerator: 4, denominator: 4)
        }
        return durations[measureIndex]
    }
}
