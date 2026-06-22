extension Score {
    /// The `.beat` cursor `beats` quarter-note beats after `cursor`, walking measures and clamping to the
    /// score's final notated tick. A beat is `division` ticks. Returns `cursor` unchanged when `beats <= 0` or
    /// the score has no measures. Pure notation math — no tempo, no audio-engine state — so it is deterministic
    /// and is the same lookahead Android can call through a JNI bridge.
    public func cursor(advancedByBeats beats: Double, from cursor: ScoreCursor) -> ScoreCursor {
        let lengths = effectiveMeasureDurations().map { $0.ticks(division: division) }
        guard !lengths.isEmpty, beats > 0 else { return cursor }
        var measure = min(max(cursor.measureIndex, 0), lengths.count - 1)
        var tick = min(max(tickInMeasure(of: cursor), 0), lengths[measure])
        var remaining = Int((beats * Double(division)).rounded())
        while remaining > 0 {
            let ticksLeftInMeasure = lengths[measure] - tick
            if remaining <= ticksLeftInMeasure {
                return .beat(measureIndex: measure, tickInMeasure: tick + remaining)
            }
            remaining -= ticksLeftInMeasure
            if measure == lengths.count - 1 {
                return .beat(measureIndex: measure, tickInMeasure: lengths[measure])
            }
            measure += 1
            tick = 0
        }
        return .beat(measureIndex: measure, tickInMeasure: tick)
    }
}
