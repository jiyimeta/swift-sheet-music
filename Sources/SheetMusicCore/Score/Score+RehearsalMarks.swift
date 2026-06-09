/// A rehearsal mark resolved onto the notated timeline: its text, the fraction (0...1) of the timeline it sits at,
/// and the cursor to seek to when tapped.
public struct RehearsalMarkEntry: Equatable, Sendable {
    public let text: String
    public let fraction: Double
    public let cursor: ScoreCursor

    public init(text: String, fraction: Double, cursor: ScoreCursor) {
        self.text = text
        self.fraction = fraction
        self.cursor = cursor
    }
}

extension Score {
    /// Rehearsal marks across the score, each placed by its tempo-weighted time fraction. Empty when the score has no
    /// marks or zero notated duration. Ordered by position.
    public func rehearsalMarks() -> [RehearsalMarkEntry] {
        let total = notatedDurationSeconds
        guard total > 0 else { return [] }
        var marks: [RehearsalMarkEntry] = []
        for (measureIndex, systemMeasure) in systemMeasures.enumerated() {
            for positioned in systemMeasure.elements {
                guard case let .rehearsalMark(mark) = positioned.element else { continue }
                let tick = positioned.position.ticks(division: division)
                let cursor = ScoreCursor.beat(measureIndex: measureIndex, tickInMeasure: tick)
                let fraction = min(max(seconds(at: cursor) / total, 0), 1)
                marks.append(RehearsalMarkEntry(text: mark.text, fraction: fraction, cursor: cursor))
            }
        }
        return marks
    }
}
