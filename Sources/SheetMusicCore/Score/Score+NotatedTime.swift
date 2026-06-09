extension Score {
    /// Per-measure tick length, indexed by measure number.
    private func measureTickLengths() -> [Int] {
        effectiveMeasureDurations().map { $0.ticks(division: division) }
    }

    /// Seconds a measure of `ticks` length occupies at the quarter-BPM governing its downbeat.
    private func measureSeconds(measureIndex: Int, ticks: Int) -> Double {
        let bpm = max(1, effectiveQuarterBpm(at: .beat(measureIndex: measureIndex, tickInMeasure: 0)))
        let secondsPerTick = (60.0 / bpm) / Double(max(1, division))
        return Double(ticks) * secondsPerTick
    }

    /// Total notated duration in seconds (each measure counted once — no repeat expansion).
    public var notatedDurationSeconds: Double {
        measureTickLengths().enumerated().reduce(0.0) { acc, pair in
            acc + measureSeconds(measureIndex: pair.offset, ticks: pair.element)
        }
    }

    /// Cumulative seconds from the score's start to `cursor`.
    public func seconds(at cursor: ScoreCursor) -> Double {
        let lengths = measureTickLengths()
        guard !lengths.isEmpty else { return 0 }
        let measure = min(max(cursor.measureIndex, 0), lengths.count - 1)
        var seconds = 0.0
        for i in 0 ..< measure {
            seconds += measureSeconds(measureIndex: i, ticks: lengths[i])
        }
        let measureTicks = lengths[measure]
        guard measureTicks > 0 else { return seconds }
        let tick = min(max(tickInMeasure(of: cursor), 0), measureTicks)
        seconds += Double(tick) / Double(measureTicks) * measureSeconds(measureIndex: measure, ticks: measureTicks)
        return seconds
    }

    /// Inverse of `seconds(at:)`: the `.beat` cursor at `seconds` from the start, clamped to
    /// `0 ... notatedDurationSeconds`.
    public func cursor(atSeconds seconds: Double) -> ScoreCursor {
        let lengths = measureTickLengths()
        guard !lengths.isEmpty else { return .beat(measureIndex: 0, tickInMeasure: 0) }
        let target = max(0, seconds)
        var elapsed = 0.0
        for (i, ticks) in lengths.enumerated() {
            let measureDuration = measureSeconds(measureIndex: i, ticks: ticks)
            let isLast = i == lengths.count - 1
            if target < elapsed + measureDuration || isLast {
                let into = measureDuration > 0 ? (target - elapsed) / measureDuration : 0
                let clamped = min(max(into, 0), 1)
                let tick = min(Int((clamped * Double(ticks)).rounded()), ticks)
                return .beat(measureIndex: i, tickInMeasure: tick)
            }
            elapsed += measureDuration
        }
        return .beat(measureIndex: lengths.count - 1, tickInMeasure: lengths.last ?? 0)
    }
}
