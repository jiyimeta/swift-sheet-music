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

    /// How far into a notional FULL bar each measure's content starts —
    /// 0 for every ordinary measure, and the shortfall for a pickup.
    ///
    /// MuseScore's `Measure::anacrusisOffset()`
    /// (`engraving/dom/measure.cpp`): `isAnacrusis() ? timesig() -
    /// ticks() : 0`, where `isAnacrusis()` is an irregular measure
    /// shorter than its own time signature. A measure carrying an
    /// explicit `actualLength` IS the irregular one in this model, so
    /// that is the test here.
    ///
    /// **What it is for.** Anything that reads a beat position out of a
    /// tick — swing's `startTick % swingBeat` above all — has to measure
    /// from the BAR, not from the start of the score, or a pickup
    /// shifts the grid for every bar that follows it. Adding this
    /// offset puts a pickup's own content at the end of the notional
    /// bar, which is where it is heard: the single eighth of a 1/8
    /// pickup in 4/4 lands on the last eighth, an up-beat.
    ///
    /// (Origin 2026-09-20: eighth swing played backwards — down-beats
    /// short, up-beats long — on every score with a pickup, because the
    /// renderer measured the swing grid from the score's tick 0. A 1/8
    /// pickup puts every later bar line at `tick % 480 == 240`, which
    /// is exactly the test for an up-beat, so the two halves of every
    /// pair swapped roles. Sixteenth swing was untouched, its pair
    /// being 240 ticks, which is what made the report read as a
    /// unit-specific bug.)
    public func anacrusisOffsets() -> [Fraction] {
        var prevailing = Fraction(numerator: 4, denominator: 4)
        var result: [Fraction] = []
        result.reserveCapacity(count)
        for measure in self {
            outer: for voice in measure.voices {
                for el in voice.elements {
                    if case let .timeSignature(ts) = el {
                        prevailing = Fraction(
                            numerator: ts.numerator,
                            denominator: ts.denominator,
                        )
                        break outer
                    }
                }
            }
            guard let actual = measure.actualLength else {
                result.append(Fraction(numerator: 0, denominator: 1))
                continue
            }
            // `Fraction` keeps its denominator positive, so the sign lives in the numerator — and it is not
            // `Comparable`, which is why this reads the numerator rather than writing `shortfall > 0`.
            let shortfall = prevailing - actual
            result.append(
                shortfall.numerator > 0
                    ? shortfall
                    : Fraction(numerator: 0, denominator: 1),
            )
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
