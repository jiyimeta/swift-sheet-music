import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Decompose a tick count into a sequence of standard
    /// `NoteDuration` values that sum to the original count. Used
    /// outside tuplet ranges so unusual durations (e.g. a 1200-tick
    /// rest filling beats 2.5..4) become idiomatic notation
    /// (`[eighth, half]`) rather than `.fraction(5/8)` which
    /// `DurationInterpretation` mis-decomposes as a triplet-scaled
    /// triple-dotted half.
    ///
    /// Algorithm:
    ///   - Walk binary + (up to `maxDots`-dotted) candidates from
    ///     largest to smallest. Take the first whose length fits in
    ///     `remaining` AND is metrically aligned at the current
    ///     measure-relative offset (= starts at a multiple of its
    ///     own base value AND doesn't extend past the next-stronger
    ///     metric boundary).
    ///   - Residual ticks fall through to `.fraction` as a last
    ///     resort.
    static func decomposeIntoStandardDurations(
        ticks: Int,
        division: Int,
        offsetInMeasure: Int,
        maxDots: Int,
    ) -> [NoteDuration] {
        let candidates = decompositionCandidates(maxDots: maxDots, division: division)
        var result: [NoteDuration] = []
        var remaining = ticks
        var offset = offsetInMeasure
        while remaining > 0 {
            let chosen = candidates.first { c in
                c.ticks > 0 && c.ticks <= remaining
                    && metricallyAligned(
                        ticks: c.ticks, baseTicks: c.baseTicks, at: offset,
                    )
            }
            guard let c = chosen else { break }
            result.append(c.duration)
            remaining -= c.ticks
            offset += c.ticks
        }
        if remaining > 0 {
            result.append(.fraction(Fraction(numerator: remaining, denominator: 4 * division)))
        }
        return result
    }

    /// One entry in the decomposition priority list: the chosen
    /// `NoteDuration`, its tick value, and the tick value of its
    /// underlying base (= itself for binary durations, ticks × 2/3
    /// for single-dotted durations).
    struct DurationCandidate {
        let duration: NoteDuration
        let ticks: Int
        let baseTicks: Int
    }

    /// Candidate durations sorted descending by tick value.
    /// Includes binary forms unconditionally; `maxDots > 0`
    /// interleaves the corresponding 1..maxDots-dotted variants
    /// of each binary duration. Each variant carries its
    /// underlying base value so `metricallyAligned` can apply the
    /// same scope rule to single, double, and triple dots.
    static func decompositionCandidates(
        maxDots: Int, division: Int,
    ) -> [DurationCandidate] {
        let bases: [NoteDuration] = [
            .whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond,
            .sixtyFourth, .oneTwentyEighth,
        ]
        var all: [DurationCandidate] = bases.map {
            let t = $0.ticks(division: division)
            return DurationCandidate(duration: $0, ticks: t, baseTicks: t)
        }
        if maxDots > 0 {
            for dots in 1 ... maxDots {
                let multiplier = (1 << (dots + 1)) - 1 // 3, 7, 15, 31, …
                let denominator = 1 << dots // 2, 4, 8, 16, …
                for b in bases {
                    let baseT = b.ticks(division: division)
                    let dottedT = baseT * multiplier / denominator
                    if dottedT <= 0 || baseT * multiplier % denominator != 0 {
                        continue
                    }
                    all.append(DurationCandidate(
                        duration: b.dotted(dots),
                        ticks: dottedT,
                        baseTicks: baseT,
                    ))
                }
            }
        }
        return all.sorted { $0.ticks > $1.ticks }
    }

    /// True if a duration with `ticks` (and underlying `baseTicks`,
    /// which equals `ticks` for binary forms) placed at
    /// measure-relative `offset` is metrically idiomatic. Either:
    ///   (a) start-aligned: the duration starts on a multiple of
    ///       its base value AND fits inside the stronger
    ///       (2 × baseTicks) scope box, OR
    ///   (b) end-aligned: the duration ends exactly on a stronger
    ///       (2 × baseTicks) boundary AND its start lies inside
    ///       the same stronger box
    /// Case (b) lets a syncopated dotted-quarter at offset 240
    /// stand as a single value when its end falls on the
    /// half-measure boundary (a recognised engraving pattern).
    /// Both clauses still reject crossings that span two scope
    /// boxes (e.g. dotted-half at offset 240, dotted-eighth at
    /// offset 840).
    static func metricallyAligned(
        ticks: Int, baseTicks: Int, at offset: Int,
    ) -> Bool {
        guard ticks > 0, baseTicks > 0 else { return true }
        let stronger = baseTicks * 2
        // (a) start-aligned at base, fits in stronger scope.
        if offset % baseTicks == 0
            && (offset % stronger) + ticks <= stronger
        {
            return true
        }
        // (b) end-aligned at stronger boundary, start inside the
        //     same stronger scope box.
        let endTick = offset + ticks
        if endTick % stronger == 0 {
            return offset >= endTick - stronger
        }
        return false
    }
}
