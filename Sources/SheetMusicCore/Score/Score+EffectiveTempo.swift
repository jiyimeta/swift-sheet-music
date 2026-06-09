extension Score {
    /// The tempo marking governing `cursor` — the most recent `SystemElement.tempo` at or before the cursor's measure
    /// and in-measure tick — or `nil` when none precedes the position (or the score carries none). A `nil` cursor is
    /// treated as the very start of the score, so it yields the opening marking.
    public func governingTempo(at cursor: ScoreCursor?) -> Tempo? {
        guard !systemMeasures.isEmpty else { return nil }
        let cursorMeasure = cursor?.measureIndex ?? 0
        let cursorTick = cursor.map { tickInMeasure(of: $0) } ?? 0
        let lastMeasure = min(cursorMeasure, systemMeasures.count - 1)

        var governing: Tempo?
        for measureIndex in 0 ... lastMeasure {
            let isCursorMeasure = measureIndex == cursorMeasure
            for positioned in systemMeasures[measureIndex].elements {
                guard case let .tempo(tempo) = positioned.element else { continue }
                // In the cursor's own measure, a marking only takes effect once the cursor reaches its tick.
                if isCursorMeasure, positioned.position.ticks(division: division) > cursorTick { continue }
                governing = tempo
            }
        }
        return governing
    }

    /// Quarter-note BPM in force at `cursor` — falls back to MuseScore's 120 BPM default when no marking governs the
    /// position. A `nil` cursor yields the opening tempo.
    public func effectiveQuarterBpm(at cursor: ScoreCursor?) -> Double {
        (governingTempo(at: cursor)?.beatsPerSecond ?? 2.0) * 60
    }
}
