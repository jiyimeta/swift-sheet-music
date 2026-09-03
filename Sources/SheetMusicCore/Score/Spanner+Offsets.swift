import SheetMusicFoundation

extension Spanner {
    /// `(nextMeasuresOffset, nextFractionsOffset)` for a spanner that begins on the element at `start` and ends at
    /// the absolute position `end` — **MuseScore's `<next>` writer**, and deliberately not an inverse of
    /// `LayoutEngine.endAnchor`, which is many-to-one (`(1, nil)` and `(1, 0/1)`, `(2, -1/8)` and `(1, 7/8)`, all
    /// resolve alike, so inverting it would pick a spelling MuseScore does not write).
    ///
    /// The rule (`rw/write/connectorinfowriter.cpp:82-96` and `:124-127`, `dom/location.cpp:82-93`): the writer
    /// takes `m = score->tick2measure(tick2)`, records `(m.index, tick2 - m.startTick)`, then subtracts the begin
    /// side's own `(measure, rtick)`. So `measures = m - start.measureIndex` and
    /// `fractions = (tick2 - m.startTick) - startRtick`, omitted when zero.
    ///
    /// Which measure `tick2` "falls in" is decided by `MeasureBaseList::measureByTick`
    /// (`dom/measurebase.cpp:943-970`) — `upper_bound(tick)` stepped back one, i.e. the last measure starting at
    /// or before `tick`, and `nullptr` only past the score's end tick. Hence the two boundary cases this walk
    /// reproduces exactly:
    ///
    /// - a `tick2` **on a bar line** belongs to the NEXT measure, at offset 0 inside it;
    /// - a `tick2` **at the score end** belongs to the LAST measure, at offset = that measure's length. It is not
    ///   past the end tick, so the step-back lands on the last measure rather than returning nothing.
    ///
    /// `nil` when `start` does not resolve, or when `end` precedes `start` — a spanner that runs backwards is a
    /// caller error, not a spelling.
    static func offsets(
        from start: VoiceElementID, to end: ScoreTickPosition, in score: Score,
    ) -> (measures: Int, fractions: Fraction?)? {
        guard let startOnset = score.onset(of: start), let staff = score[start.staff] else { return nil }
        let durations = staff.measures.effectiveMeasureDurations()
        guard durations.indices.contains(end.measure), start.measureIndex <= end.measure else { return nil }

        // Roll a bar-end (or an overflowing) tick forward into the measure that CONTAINS it. The last measure is
        // where the roll stops: at the score end MuseScore's own lookup stays there too.
        var measure = end.measure
        var tick = end.tick
        while measure < staff.measures.count - 1,
              tick >= durations[measure].ticks(division: score.division)
        {
            tick -= durations[measure].ticks(division: score.division)
            measure += 1
        }
        guard ScoreTickPosition(measure: measure, tick: tick) >= startOnset else { return nil }

        let fractionTicks = tick - startOnset.tick
        return (
            measures: measure - start.measureIndex,
            fractions: fractionTicks == 0 ? nil : Fraction(ticks: fractionTicks, division: score.division),
        )
    }
}
