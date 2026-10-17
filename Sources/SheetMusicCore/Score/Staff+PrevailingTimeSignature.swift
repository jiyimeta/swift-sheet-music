extension Measure {
    /// The first `.timeSignature` this bar declares, in voice order then element order — the one that governs the bar,
    /// following the rule `[Measure].effectiveMeasureDurations()` uses. `nil` when the bar declares none.
    var declaredTimeSignature: TimeSignature? {
        for voice in voices {
            for element in voice.elements {
                if case let .timeSignature(timeSignature) = element { return timeSignature }
            }
        }
        return nil
    }
}

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
            if let declared = measure.declaredTimeSignature { prevailing = declared }
        }
        return prevailing
    }
}
