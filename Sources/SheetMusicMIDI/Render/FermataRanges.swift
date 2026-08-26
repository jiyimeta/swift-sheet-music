import SheetMusicCore
import SheetMusicFoundation

/// One resolved fermata: the original-tick range its anchor chord/rest
/// occupies, and the hold ratio to apply during that range.
///
/// Anchoring a fermata to its chord is `Score.fermataHolds()`'s job — one derivation, shared with
/// the notated-time API so the SMF's holds and the score's cannot disagree. What lives here is only
/// the projection of those holds onto the renderer's absolute tick spine
/// (`MidiRenderer.fermataBookendEvents`) and the sweep that turns them into tempo events.
struct FermataRange: Equatable {
    let startTick: Int // original (pre-repeat) tick
    let endTick: Int // exclusive
    let stretch: Double // ≥ 1.0; fermata hold multiplier applied to the note duration
}

enum FermataRanges {
    private struct DedupeKey: Hashable {
        let startTick: Int
        let endTick: Int
    }

    /// Group by (startTick, endTick); within each group keep the
    /// largest stretch. Returns ranges sorted by startTick then
    /// endTick — required by the sweep-merge consumer.
    static func dedupeMaxStretch(_ ranges: [FermataRange]) -> [FermataRange] {
        var bestByKey: [DedupeKey: FermataRange] = [:]
        for r in ranges {
            let key = DedupeKey(startTick: r.startTick, endTick: r.endTick)
            if let prev = bestByKey[key], prev.stretch >= r.stretch { continue }
            bestByKey[key] = r
        }
        return bestByKey.values.sorted { lhs, rhs in
            (lhs.startTick, lhs.endTick) < (rhs.startTick, rhs.endTick)
        }
    }
}

/// Sorted (tick, beats-per-second) checkpoints. Lookup returns the
/// last entry whose tick is ≤ the queried tick. Defaults to a single
/// `(0, 2.0)` entry (= 120 BPM, MuseScore default) so empty scores
/// still answer correctly.
struct TempoTimeline: Equatable {
    let entries: [Entry]
    struct Entry: Equatable {
        let tick: Int
        let bps: Double
    }

    init(entries: [(tick: Int, bps: Double)]) {
        var sorted = entries.map { Entry(tick: $0.tick, bps: $0.bps) }
        sorted.sort { $0.tick < $1.tick }
        if sorted.first?.tick != 0 {
            sorted.insert(Entry(tick: 0, bps: 2.0), at: 0)
        }
        self.entries = sorted
    }

    func bps(at tick: Int) -> Double {
        var lo = 0
        var hi = entries.count - 1
        var pick = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if entries[mid].tick <= tick {
                pick = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return entries[pick].bps
    }

    /// Build a tempo timeline from a staff's measure tick budgets
    /// combined with the score-level tempo entries on
    /// `systemMeasures`. Tempo events are filtered to ones that
    /// would render against this staff: system-level (originalStaff
    /// = nil) maps to the canonical staff 0; staff-bound tempo
    /// markers map to their originating staff. Currently the
    /// fermata renderer is invoked once per staff, so the filter is
    /// done at the call site by passing the matching staff address.
    static func build(
        measures: [Measure],
        systemMeasures: [SystemMeasure],
        division: Int,
    ) -> TempoTimeline {
        var entries: [(tick: Int, bps: Double)] = [(0, 2.0)]
        var measureBases: [Int] = []
        let measureDurations = measures.effectiveMeasureDurations()
        do {
            var acc = 0
            for (i, m) in measures.enumerated() {
                measureBases.append(acc)
                let mDur = i < measureDurations.count
                    ? measureDurations[i]
                    : Fraction(numerator: 4, denominator: 4)
                acc += MidiRenderer.measureTicks(
                    measure: m, division: division,
                    measureDuration: mDur,
                )
            }
        }
        for (measureIndex, systemMeasure) in systemMeasures.enumerated() {
            guard measureIndex < measureBases.count else { continue }
            let measureBase = measureBases[measureIndex]
            for positioned in systemMeasure.elements {
                guard case let .tempo(tempo) = positioned.element else { continue }
                let tick = measureBase + positioned.position.ticks(division: division)
                entries.append((tick: tick, bps: tempo.beatsPerSecond))
            }
        }
        entries.sort { $0.tick < $1.tick }
        return TempoTimeline(entries: entries)
    }
}

extension FermataRanges {
    /// Sweep-merge result. `openEvents` are inserted AFTER the voice
    /// walks (so they sort after same-tick `.tempo` events), and
    /// `closeEvents` are inserted BEFORE the voice walks (so they
    /// sort before same-tick `.tempo`). The renderer's stable sort
    /// realises the close → .tempo → open ordering documented in the
    /// fermata-midi spec.
    struct TempoEvents: Equatable {
        var openEvents: [TimedMidiEvent]
        var closeEvents: [TimedMidiEvent]
    }

    /// Convert a list of FermataRanges into tempo bookend events using
    /// piecewise-max sweep over the original-tick timeline. At every
    /// boundary tick the effective stretch is the `max` of all
    /// covering ranges; we emit a tempo meta only when the effective
    /// stretch transitions.
    static func tempoEvents(
        ranges: [FermataRange],
        timeline: TempoTimeline,
    ) -> TempoEvents {
        guard !ranges.isEmpty else { return TempoEvents(openEvents: [], closeEvents: []) }
        var sortedByStart = ranges.sorted { $0.startTick < $1.startTick }
        let boundaries = uniqueBoundaries(of: ranges)
        var active: [FermataRange] = []
        var prevEffective = 1.0
        var open: [TimedMidiEvent] = []
        var close: [TimedMidiEvent] = []

        for tick in boundaries {
            // Drop ranges that have already ended.
            active.removeAll { $0.endTick <= tick }
            // Admit any ranges starting at exactly this tick.
            while let next = sortedByStart.first, next.startTick == tick {
                active.append(next)
                sortedByStart.removeFirst()
            }
            let effective = active.map(\.stretch).max() ?? 1.0
            guard effective != prevEffective else { continue }

            let baseBps = timeline.bps(at: tick)
            let bookendBps = baseBps / effective
            let micros = Int((1_000_000.0 / bookendBps).rounded())
            let event = TimedMidiEvent(
                tick: tick, event: .meta(.tempo(microsecondsPerQuarter: micros)),
            )
            // Classification: "close" only when fully restored to the
            // baseline (no fermatas active). Any transition that leaves
            // at least one fermata active is an "open" — it must sort
            // AFTER any same-tick `.tempo` so the active stretch wins.
            if effective == 1.0 {
                close.append(event)
            } else {
                open.append(event)
            }
            prevEffective = effective
        }

        return TempoEvents(openEvents: open, closeEvents: close)
    }

    private static func uniqueBoundaries(of ranges: [FermataRange]) -> [Int] {
        var set = Set<Int>()
        for r in ranges {
            set.insert(r.startTick)
            set.insert(r.endTick)
        }
        return set.sorted()
    }
}
