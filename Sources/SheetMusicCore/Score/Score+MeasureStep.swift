public enum MeasureStepDirection: Sendable { case backward, forward }

extension Score {
    /// The `.beat` cursor for stepping one measure from `cursor`. Forward advances to the next measure's downbeat,
    /// clamped to the last measure. Backward uses the media-player idiom: if the cursor is still within the first beat
    /// of its measure, go to the previous measure's downbeat; otherwise restart the current measure. Clamped to 0.
    public func cursorSteppingMeasure(from cursor: ScoreCursor, direction: MeasureStepDirection) -> ScoreCursor {
        let count = effectiveMeasureDurations().count
        guard count > 0 else { return .beat(measureIndex: 0, tickInMeasure: 0) }
        let current = min(max(cursor.measureIndex, 0), count - 1)
        switch direction {
        case .forward:
            return .beat(measureIndex: min(current + 1, count - 1), tickInMeasure: 0)
        case .backward:
            let beat = beatTicks(atMeasure: current) ?? Int.max
            let target = tickInMeasure(of: cursor) < beat ? current - 1 : current
            return .beat(measureIndex: max(target, 0), tickInMeasure: 0)
        }
    }
}
