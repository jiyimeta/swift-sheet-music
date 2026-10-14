extension Score {
    /// The tempo marking governing `cursor` — the most recent `SystemElement.tempo` at or before the cursor's measure
    /// and in-measure tick — or `nil` when none precedes the position (or the score carries none). A `nil` cursor is
    /// treated as the very start of the score, so it yields the opening marking.
    ///
    /// This is the marking, not what plays — a muted marking, an "a tempo" and a "tempo primo" govern with a number
    /// the score does not play there; `effectiveTempo(at:)` is what plays.
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

    /// What plays at `cursor`: the tempo map's point in force there (`resolvedTempoMap()`), with the beat to count it
    /// in; `nil` before the first point. A `nil` cursor is the start of the score. `governingTempo(at:)` answers a
    /// different question — which marking governs the position: an "a tempo" governs with a number it does not play.
    public func effectiveTempo(at cursor: ScoreCursor?) -> ResolvedTempoMap.Point? {
        let map = resolvedTempoMap()
        guard let cursor else { return map.point(inForceAtMeasure: 0, tickInMeasure: 0) }
        return map.point(inForceAtMeasure: cursor.measureIndex, tickInMeasure: tickInMeasure(of: cursor))
    }

    /// Quarter-note BPM in force at `cursor` (`effectiveTempo(at:)`); MuseScore's 120 BPM default where nothing is.
    public func effectiveQuarterBpm(at cursor: ScoreCursor?) -> Double {
        (effectiveTempo(at: cursor)?.beatsPerSecond ?? ResolvedTempoMap.defaultBeatsPerSecond) * 60
    }
}
