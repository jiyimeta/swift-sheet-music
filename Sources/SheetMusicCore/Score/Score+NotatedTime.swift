extension Score {
    /// Per-measure tick length, indexed by measure number.
    private func measureTickLengths() -> [Int] {
        effectiveMeasureDurations().map { $0.ticks(division: division) }
    }

    /// Extra ticks each measure is held for by the fermatas in it, indexed by measure number.
    ///
    /// A fermata stretches its chord rather than occupying time of its own, so it never changes a
    /// bar's tick LENGTH — but it does change how long that bar takes, and a clock that ignored it
    /// reported a piece as shorter than it plays. Kept in ticks (not seconds) so the bar's own
    /// governing tempo converts both parts the same way.
    private func measureHoldTicks() -> [Double] {
        var extra = [Double](repeating: 0, count: measureTickLengths().count)
        for hold in fermataHolds() where extra.indices.contains(hold.measureIndex) {
            extra[hold.measureIndex] += hold.extraTicks
        }
        return extra
    }

    /// Seconds a measure of `ticks` length occupies at the quarter-BPM governing its downbeat.
    private func measureSeconds(measureIndex: Int, ticks: Double) -> Double {
        let bpm = max(1, effectiveQuarterBpm(at: .beat(measureIndex: measureIndex, tickInMeasure: 0)))
        let secondsPerTick = (60.0 / bpm) / Double(max(1, division))
        return ticks * secondsPerTick
    }

    /// Total notated duration in seconds (each measure counted once — no repeat expansion), fermata
    /// holds included.
    public var notatedDurationSeconds: Double {
        let holds = measureHoldTicks()
        return measureTickLengths().enumerated().reduce(0.0) { acc, pair in
            acc + measureSeconds(
                measureIndex: pair.offset, ticks: Double(pair.element) + holds[pair.offset],
            )
        }
    }

    /// Cumulative seconds from the score's start to `cursor`.
    ///
    /// A measure's hold is treated as part of that measure's span: the fraction into the bar is
    /// still taken from the notated ticks, so a cursor halfway through the bar by tick reads as
    /// halfway by time. Resolving *where inside the bar* the hold falls would need the tick map
    /// this measure-granular API deliberately doesn't build.
    public func seconds(at cursor: ScoreCursor) -> Double {
        let lengths = measureTickLengths()
        guard !lengths.isEmpty else { return 0 }
        let holds = measureHoldTicks()
        let measure = min(max(cursor.measureIndex, 0), lengths.count - 1)
        var seconds = 0.0
        for i in 0 ..< measure {
            seconds += measureSeconds(measureIndex: i, ticks: Double(lengths[i]) + holds[i])
        }
        let measureTicks = lengths[measure]
        guard measureTicks > 0 else { return seconds }
        let tick = min(max(tickInMeasure(of: cursor), 0), measureTicks)
        let span = measureSeconds(
            measureIndex: measure, ticks: Double(measureTicks) + holds[measure],
        )
        seconds += Double(tick) / Double(measureTicks) * span
        return seconds
    }

    /// Inverse of `seconds(at:)`: the `.beat` cursor at `seconds` from the start, clamped to
    /// `0 ... notatedDurationSeconds`.
    public func cursor(atSeconds seconds: Double) -> ScoreCursor {
        let lengths = measureTickLengths()
        guard !lengths.isEmpty else { return .beat(measureIndex: 0, tickInMeasure: 0) }
        let holds = measureHoldTicks()
        let target = max(0, seconds)
        var elapsed = 0.0
        for (i, ticks) in lengths.enumerated() {
            let measureDuration = measureSeconds(
                measureIndex: i, ticks: Double(ticks) + holds[i],
            )
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
