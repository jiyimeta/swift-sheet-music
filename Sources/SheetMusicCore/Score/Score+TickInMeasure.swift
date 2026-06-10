extension Score {
    /// In-measure tick offset of the voice element identified by `itemID`. Returns `nil` when the path doesn't resolve.
    public func resolveTickInMeasure(for itemID: ScoreItemID) -> Int? {
        guard let staff = self[itemID.staff] else { return nil }
        guard staff.measures.indices.contains(itemID.measureIndex) else { return nil }
        let voices = staff.measures[itemID.measureIndex].voices
        guard voices.indices.contains(itemID.voiceIndex) else { return nil }
        let elements = voices[itemID.voiceIndex].elements
        guard itemID.elementIndex >= 0, itemID.elementIndex <= elements.count else { return nil }

        let measureDuration = staff.measures.effectiveMeasureDurations()[itemID.measureIndex]
        var tick = 0
        for i in 0 ..< itemID.elementIndex {
            if case let .chord(chord) = elements[i] {
                tick += chord.duration.resolved(in: measureDuration).ticks(division: division)
            }
        }
        return tick
    }

    /// In-measure tick offset of a cursor regardless of its `.item` vs `.beat` flavour.
    public func tickInMeasure(of cursor: ScoreCursor) -> Int {
        switch cursor {
        case let .beat(_, tick): tick
        case let .item(id): resolveTickInMeasure(for: id) ?? 0
        }
    }

    /// Tick length of one notated beat (the prevailing time-signature denominator unit) in `measureIndex`. Carries the
    /// time signature forward from earlier measures, defaulting to 4/4. `nil` when the index is out of range.
    public func beatTicks(atMeasure measureIndex: Int) -> Int? {
        guard let measures = parts.first?.staves.first?.measures,
              measures.indices.contains(measureIndex)
        else { return nil }
        var denominator = 4
        for i in 0 ... measureIndex {
            for case let .timeSignature(ts) in measures[i].voices.flatMap(\.elements) {
                denominator = ts.denominator
                break
            }
        }
        return 4 * division / denominator
    }
}
