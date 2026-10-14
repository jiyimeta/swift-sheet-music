extension Score {
    /// Total notated duration in seconds (each measure counted once — no repeat expansion), fermata
    /// holds included, every tempo-map point counted (`NotatedClock`).
    ///
    /// Builds the clock on each call: a caller that asks repeatedly keeps one `notatedClock()` and reads
    /// `durationSeconds` from it.
    public var notatedDurationSeconds: Double {
        notatedClock().durationSeconds
    }

    /// Cumulative seconds from the score's start to `cursor`.
    ///
    /// A measure's hold is treated as part of that measure's span, spread over its ticks: resolving *where inside the
    /// bar* the hold falls would need the tick map this measure-granular API deliberately doesn't build.
    public func seconds(at cursor: ScoreCursor, clock: NotatedClock? = nil) -> Double {
        let clock = clock ?? notatedClock()
        return clock.seconds(measureIndex: cursor.measureIndex, tickInMeasure: tickInMeasure(of: cursor))
    }

    /// Inverse of `seconds(at:)`: the `.beat` cursor at `seconds` from the start, clamped to
    /// `0 ... notatedDurationSeconds`. Pass a cached `clock` to skip rebuilding the timeline.
    public func cursor(atSeconds seconds: Double, clock: NotatedClock? = nil) -> ScoreCursor {
        (clock ?? notatedClock()).cursor(atSeconds: seconds)
    }
}
