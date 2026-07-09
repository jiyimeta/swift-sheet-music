import SheetMusicCore

/// Computes the count-in ("pre-roll") click schedule for playback starting at `startCursor`: one prepended
/// measure of the effective meter, an anacrusis right-align shim, and the mid-measure lead-in — as ticks,
/// so the playback engine can prepend them to the score's MIDI sequence. Pure; shared by iOS + Android.
public enum CountInBeats {
    public struct Result: Sendable, Equatable {
        /// Total ticks occupied by the pre-roll region (real playback begins here).
        public let preRollTicks: Int
        /// Click beats at ticks in `[0, preRollTicks)`. `isDownbeat` marks the accented (strong) clicks.
        public let beats: [MetronomeBeat]
        /// Quarter-note BPM governing the start position — the engine seeds the pre-roll tempo with it.
        public let quarterBpm: Double

        public init(preRollTicks: Int, beats: [MetronomeBeat], quarterBpm: Double) {
            self.preRollTicks = preRollTicks
            self.beats = beats
            self.quarterBpm = quarterBpm
        }
    }

    public static func compute(score: Score, startCursor: ScoreCursor?) -> Result? {
        guard let measures = score.parts.first?.staves.first?.measures, !measures.isEmpty else { return nil }
        let division = score.division
        guard division > 0 else { return nil }

        let startMeasure = min(max(startCursor?.measureIndex ?? 0, 0), measures.count - 1)
        let startTickInMeasure = startCursor.map { score.tickInMeasure(of: $0) } ?? 0

        /// Carried-forward nominal time signature governing `index`, defaulting 4/4 — first TS in a measure
        /// governs it, and a chord ends the search for that measure (mirrors `MetronomeBeat`'s walk).
        func nominalTimeSignature(at index: Int) -> TimeSignature {
            var ts = TimeSignature(numerator: 4, denominator: 4)
            for mi in 0 ... index {
                for element in measures[mi].voices.first?.elements ?? [] {
                    if case let .timeSignature(t) = element { ts = t; break }
                    if case .chord = element { break }
                }
            }
            return ts
        }

        let ts = nominalTimeSignature(at: startMeasure)
        let step = max(1, division * 4 / ts.denominator)
        let numerator = max(1, ts.numerator)
        let nominalTicks = numerator * step

        let shim = anacrusisShim(
            measures: measures,
            startMeasure: startMeasure,
            division: division,
            nominalTicks: nominalTicks,
        )
        let quarterBpm = score.effectiveQuarterBpm(at: startCursor)
        guard quarterBpm > 0 else { return nil }

        let preRollTicks = nominalTicks + shim + startTickInMeasure
        var beats: [MetronomeBeat] = []
        var tick = 0
        var k = 0
        while tick < preRollTicks {
            beats.append(MetronomeBeat(tick: tick, isDownbeat: k == 0 || k == numerator))
            tick += step
            k += 1
        }
        guard !beats.isEmpty else { return nil }
        return Result(preRollTicks: preRollTicks, beats: beats, quarterBpm: quarterBpm)
    }

    /// Missing-beat shim `(nominalTicks − actualTicks)` when starting inside an anacrusis (measure 0 only);
    /// 0 otherwise. Detects both encodings: MuseScore (`irregular`/`actualLength`) and MusicXML (content sum).
    private static func anacrusisShim(
        measures: [Measure],
        startMeasure: Int,
        division: Int,
        nominalTicks: Int,
    ) -> Int {
        guard startMeasure == 0 else { return 0 }
        let actual = actualTicks(measures: measures, index: 0, division: division, nominalTicks: nominalTicks)
        let isAnacrusis = measures[0].irregular || (actual > 0 && actual < nominalTicks)
        return isAnacrusis ? max(0, nominalTicks - actual) : 0
    }

    /// Actual filled ticks of a measure: `actualLength` when present (MuseScore), else the sum of voice-0
    /// timed element durations (MusicXML pickups, whose `actualLength` is nil).
    private static func actualTicks(measures: [Measure], index: Int, division: Int, nominalTicks: Int) -> Int {
        if let actualLength = measures[index].actualLength { return actualLength.ticks(division: division) }
        guard let voice0 = measures[index].voices.first else { return 0 }
        // Nominal measure duration as a Fraction, for resolving whole-measure (`.measure`) rests.
        let measureDuration = Fraction(numerator: max(1, nominalTicks), denominator: 4 * division)
        return voice0.elements.reduce(0) { $0 + ($1.tickCount(division: division, in: measureDuration) ?? 0) }
    }
}
