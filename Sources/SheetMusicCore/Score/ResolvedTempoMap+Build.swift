import SheetMusicFoundation

extension Score {
    /// The score's tempo map (`ResolvedTempoMap`), built on each call — a consumer that reads it many times builds it
    /// once.
    public func resolvedTempoMap() -> ResolvedTempoMap {
        ResolvedTempoMap.markings(lane: systemMeasures.values, division: division)
    }
}

extension ResolvedTempoMap {
    /// The tempo markings' points alone: every `SystemElement.tempo` at its own bps and beat.
    package static func markings(lane: [SystemMeasure], division: Int) -> ResolvedTempoMap {
        var points: [Point] = []
        for (measureIndex, measure) in lane.enumerated() {
            for positioned in measure.elements {
                guard case let .tempo(tempo) = positioned.element else { continue }
                points.append(Point(
                    measureIndex: measureIndex, tickInMeasure: positioned.position.ticks(division: division),
                    beatsPerSecond: tempo.beatsPerSecond, role: .marking,
                    beatNote: tempo.beatNote, beatDots: tempo.beatDots,
                ))
            }
        }
        return ResolvedTempoMap(points: inScoreOrder(points))
    }

    /// `points` sorted by position; two at one position keep the order they came in.
    static func inScoreOrder(_ points: [Point]) -> [Point] {
        points.enumerated()
            .sorted { lhs, rhs in
                (lhs.element.measureIndex, lhs.element.tickInMeasure, lhs.offset)
                    < (rhs.element.measureIndex, rhs.element.tickInMeasure, rhs.offset)
            }
            .map(\.element)
    }
}
