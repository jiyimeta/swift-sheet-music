import SheetMusicCore
import SheetMusicFoundation

/// Score-global, per-measure navigation facts merged across all
/// staves.
///
/// MuseScore replicates start/end-repeat barlines and volta spanners
/// on every staff, but writes `<Jump>` / `<Marker>` (and section
/// breaks) only on the top staff. A per-staff playback plan would
/// therefore jump on staff 0 and play straight through on staves
/// 1..n, desyncing the tracks. `ScoreNavigation` merges the union of
/// navigation facts across all staves so ONE plan can be computed and
/// shared by every staff. Mirrors the score-level walk feeding
/// `mu::engraving::RepeatList::collectRepeatListElements`
/// (repeatlist.cpp:425).
struct ScoreNavigation: Equatable {
    /// Navigation facts for one measure, index-aligned with the
    /// canonical staff's `measures` array.
    struct MeasureFacts: Equatable {
        var startRepeat = false
        /// Number of plays when this measure ends a repeat; nil = no
        /// end-repeat barline. Union across staves keeps the max.
        var endRepeatCount: Int?
        var sectionBreak = false
        /// Deduplicated by `Marker` equality — replicated system
        /// markers collapse to one; the rare per-staff distinct
        /// markers are all kept (first match wins in findMarker).
        var markers: [Marker] = []
        /// Deduplicated by `Jump` equality (MuseScore #27647: two
        /// instruments carrying the same D.S. must not double-jump).
        var jumps: [Jump] = []
        /// Canonical duration of this measure in ticks — identical on
        /// every staff by construction, taken from
        /// `parts[0].staves[0]`.
        var tickSpan: Int
    }

    /// One volta bracket projected to measure-index space.
    /// `endMeasure` is INCLUSIVE (mscx `<measures>N` covers the
    /// anchor + N−1 further measures; N=1 covers just the anchor).
    struct VoltaSpan: Equatable {
        var startMeasure: Int
        var endMeasure: Int
        var endings: [Int]

        /// Mirrors `Volta::hasEnding`.
        func hasEnding(_ playbackCount: Int) -> Bool {
            endings.contains(playbackCount)
        }

        /// Mirrors `Volta::firstEnding` — 0 when empty
        /// (repeatlist.cpp:813-819).
        var firstEnding: Int {
            endings.min() ?? 0
        }

        /// Mirrors `Volta::lastEnding` — 0 when empty
        /// (repeatlist.cpp:821-828).
        var lastEnding: Int {
            endings.max() ?? 0
        }
    }

    var measures: [MeasureFacts]
    /// All volta brackets, sorted by `startMeasure`, deduplicated
    /// across staves. Overlap splitting/merging
    /// (repeatlist.cpp:453-521) is NOT reproduced — overlapping-volta
    /// scores (repeat60-64) are a documented follow-up.
    var voltas: [VoltaSpan]
}

extension ScoreNavigation {
    /// Score-global view: union of every staff's facts, canonical
    /// spans from `parts[0].staves[0]`.
    init(score: Score) {
        let staves = score.allStaves.map(\.staff.measures)
        self.init(
            staves: staves,
            canonicalMeasures: staves.first ?? [],
            division: score.division,
        )
    }

    /// Single-staff view WITHOUT jumps / markers / section breaks —
    /// the compatibility shape behind
    /// `MidiRenderer.playbackPlan(for:division:)`. Repeats and voltas
    /// replicate across staves, so a per-staff plan built from this
    /// stays correct for legacy callers.
    init(staffMeasures: [Measure], division: Int) {
        self.init(
            staves: [staffMeasures],
            canonicalMeasures: staffMeasures,
            division: division,
        )
        for i in measures.indices {
            measures[i].markers = []
            measures[i].jumps = []
            measures[i].sectionBreak = false
        }
    }

    private init(staves: [[Measure]], canonicalMeasures: [Measure], division: Int) {
        let measureDurations = canonicalMeasures.effectiveMeasureDurations()
        var facts: [MeasureFacts] = canonicalMeasures.enumerated().map { i, measure in
            let duration = i < measureDurations.count
                ? measureDurations[i]
                : Fraction(numerator: 4, denominator: 4)
            return MeasureFacts(tickSpan: MidiRenderer.measureTicks(
                measure: measure, division: division, measureDuration: duration,
            ))
        }
        var voltaSpans: [VoltaSpan] = []
        for staffMeasures in staves {
            for (i, measure) in staffMeasures.enumerated() where i < facts.count {
                Self.mergeFacts(from: measure, into: &facts[i])
                Self.collectVoltas(
                    from: measure, at: i,
                    measureCount: facts.count, into: &voltaSpans,
                )
            }
        }
        measures = facts
        voltas = voltaSpans.sorted { $0.startMeasure < $1.startMeasure }
    }

    private static func mergeFacts(from measure: Measure, into facts: inout MeasureFacts) {
        if measure.startRepeat { facts.startRepeat = true }
        if let count = measure.endRepeatCount {
            facts.endRepeatCount = max(facts.endRepeatCount ?? 0, count)
        }
        if measure.sectionBreak { facts.sectionBreak = true }
        for marker in measure.markers where !facts.markers.contains(marker) {
            facts.markers.append(marker)
        }
        for jump in measure.jumps where !facts.jumps.contains(jump) {
            facts.jumps.append(jump)
        }
    }

    private static func collectVoltas(
        from measure: Measure, at index: Int,
        measureCount: Int, into voltaSpans: inout [VoltaSpan],
    ) {
        for voice in measure.voices {
            for element in voice.elements {
                guard case let .spanner(spanner) = element,
                      spanner.kind == .volta, !spanner.voltaEndings.isEmpty
                else { continue }
                let covered = max(1, spanner.nextMeasuresOffset)
                let span = VoltaSpan(
                    startMeasure: index,
                    endMeasure: min(index + covered - 1, measureCount - 1),
                    endings: spanner.voltaEndings,
                )
                if !voltaSpans.contains(span) {
                    voltaSpans.append(span)
                }
            }
        }
    }
}
