import SheetMusicCore
import SheetMusicFoundation

extension HairpinRamps {
    /// End tick = startTick + Σ (next-measures-worth of measure ticks)
    /// + nextFractions delta. MuseScore's `<location>` (the `<next>`
    /// child) is **relative to the begin spanner's own tick**, so the
    /// offset is added to `startTick` rather than re-derived from a
    /// measure base: a hairpin written from beat 4 to the next downbeat
    /// carries `<measures>1</measures><fractions>-7/8</fractions>`, and
    /// measuring that from the measure base instead of from beat 4
    /// lands the end before the start. Falls back to `startTick + 1` so
    /// the range stays non-empty.
    ///
    /// Same resolution as `OttavaRanges.computeEndTick` and
    /// `LayoutEngine.endAnchor`.
    static func computeEndTick(
        startTick: Int,
        startMeasureIndex: Int,
        spanner: Spanner,
        measures: [Measure],
        division: Int,
        tempoMap: ResolvedTempoMap,
    ) -> Int {
        var measureSpan = 0
        let endIndex = min(
            measures.count,
            startMeasureIndex + max(0, spanner.nextMeasuresOffset),
        )
        if startMeasureIndex < endIndex {
            let measureDurations = measures.effectiveMeasureDurations()
            for i in startMeasureIndex ..< endIndex {
                let mDuration = i < measureDurations.count
                    ? measureDurations[i]
                    : Fraction(numerator: 4, denominator: 4)
                measureSpan += MidiRenderer.measureTicks(
                    measure: measures[i], division: division,
                    measureDuration: mDuration,
                    measureIndex: i, tempoMap: tempoMap,
                )
            }
        }
        let fractionDelta = spanner.nextFractionsOffset?.ticks(division: division) ?? 0
        return max(startTick + 1, startTick + measureSpan + fractionDelta)
    }
}
