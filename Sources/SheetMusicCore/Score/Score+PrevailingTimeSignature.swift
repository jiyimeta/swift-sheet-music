extension Staff {
    /// The time signature in force at `measureIndex`: the last `.timeSignature` declared at or before that bar,
    /// following the rule `[Measure].effectiveMeasureDurations()` uses to pick a prevailing `Fraction` (the first one
    /// found in a bar governs it). `nil` when none has appeared yet, or when `measureIndex` is out of range — the
    /// caller chooses the default (4/4 everywhere in this package).
    ///
    /// Unlike the `Fraction` that table carries, this keeps the signature as written, so 6/8 is not reduced to 3/4
    /// and a compound meter can still be told from a simple one.
    func prevailingTimeSignature(upTo measureIndex: Int) -> TimeSignature? {
        guard measures.indices.contains(measureIndex) else { return nil }
        var prevailing: TimeSignature?
        for measure in measures[...measureIndex] {
            outer: for voice in measure.voices {
                for element in voice.elements {
                    if case let .timeSignature(timeSignature) = element {
                        prevailing = timeSignature
                        break outer
                    }
                }
            }
        }
        return prevailing
    }
}

extension Score {
    /// `Staff.prevailingTimeSignature(upTo:)` for the staff at `staff`; `nil` when the staff or bar does not exist
    /// or no time signature has been declared by then.
    func prevailingTimeSignature(staff: StaffAddress, measureIndex: Int) -> TimeSignature? {
        self[staff]?.prevailingTimeSignature(upTo: measureIndex)
    }
}
