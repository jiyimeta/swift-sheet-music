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
    ///   - Walk binary + (optionally) single-dotted candidates from
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
        allowDot: Bool
    ) -> [NoteDuration] {
        let candidates = decompositionCandidates(allowDot: allowDot, division: division)
        var result: [NoteDuration] = []
        var remaining = ticks
        var offset = offsetInMeasure
        while remaining > 0 {
            let chosen = candidates.first { c in
                c.ticks > 0 && c.ticks <= remaining
                    && metricallyAligned(
                        ticks: c.ticks, baseTicks: c.baseTicks, at: offset
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

    /// Candidate durations sorted descending by tick value. When
    /// `allowDot` is true, single-dotted variants of each binary
    /// duration are interleaved into the priority list.
    static func decompositionCandidates(
        allowDot: Bool, division: Int
    ) -> [DurationCandidate] {
        let bases: [NoteDuration] = [
            .whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond,
            .sixtyFourth, .oneTwentyEighth,
        ]
        var all: [DurationCandidate] = bases.map {
            let t = $0.ticks(division: division)
            return DurationCandidate(duration: $0, ticks: t, baseTicks: t)
        }
        if allowDot {
            for b in bases {
                let baseT = b.ticks(division: division)
                all.append(DurationCandidate(
                    duration: b.dotted(1),
                    ticks: baseT * 3 / 2,
                    baseTicks: baseT
                ))
            }
        }
        return all.sorted { $0.ticks > $1.ticks }
    }

    /// True if a duration with `ticks` (and underlying `baseTicks`,
    /// which equals `ticks` for binary forms) placed at
    /// measure-relative `offset` is metrically idiomatic:
    ///   - the duration starts at a multiple of its base value
    ///     (= sits on a beat-or-stronger boundary at its own level)
    ///   - the duration does not extend past the next stronger
    ///     boundary at level `2 × baseTicks`
    /// Together these reject unusual placements like a
    /// dotted-eighth at offset 840 (crosses beat 3) or a
    /// dotted-half at offset 240 (crosses half-measure twice).
    static func metricallyAligned(
        ticks: Int, baseTicks: Int, at offset: Int
    ) -> Bool {
        guard ticks > 0, baseTicks > 0 else { return true }
        if offset % baseTicks != 0 { return false }
        let stronger = baseTicks * 2
        return (offset % stronger) + ticks <= stronger
    }
}
