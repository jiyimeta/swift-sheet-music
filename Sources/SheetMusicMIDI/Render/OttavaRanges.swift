import Foundation
import SheetMusicCore

/// One resolved ottava: a tick range during which every sounding note
/// in the voice gets its pitch shifted by `semitones`. Built by
/// `OttavaRanges.collect` and consulted at chord-onset time by
/// `MidiRenderer+Voice`. End tick is half-open: a chord whose onset
/// equals `endTick` is OUTSIDE the range (the spanner ends just as
/// the next chord begins). Mirrors the layout-side range computed
/// in `LayoutEngine+Spanners.collectSpanners`.
struct OttavaRange: Equatable {
    let startTick: Int
    let endTick: Int
    let semitones: Int
}

enum OttavaRanges {
    /// Latest-starting range containing `tick`. Well-formed scores
    /// don't overlap ottavas; this is a defensive choice mirroring
    /// `HairpinRamps.active`.
    static func semitones(in ranges: [OttavaRange], at tick: Int) -> Int {
        ranges
            .filter { tick >= $0.startTick && tick < $0.endTick }
            .max(by: { $0.startTick < $1.startTick })?
            .semitones
            ?? 0
    }

    /// Walk one voice in original (pre-repeat) ticks and resolve every
    /// `<Spanner type="Ottava">` into a concrete `OttavaRange`.
    static func collect(
        voiceIndex: Int,
        staff: Staff,
        division: Int,
    ) -> [OttavaRange] {
        var ranges: [OttavaRange] = []
        var measureBase = 0
        let measureDurations = staff.measures.effectiveMeasureDurations()
        for (measureIdx, measure) in staff.measures.enumerated() {
            let measureDuration = measureIdx < measureDurations.count
                ? measureDurations[measureIdx]
                : Fraction(numerator: 4, denominator: 4)
            let mTicks = MidiRenderer.measureTicks(
                measure: measure, division: division,
                measureDuration: measureDuration,
            )
            if voiceIndex < measure.voices.count {
                walkVoice(
                    measure.voices[voiceIndex],
                    measureIdx: measureIdx,
                    measureBase: measureBase,
                    measureDuration: measureDuration,
                    measures: staff.measures,
                    division: division,
                    out: &ranges,
                )
            }
            measureBase += mTicks
        }
        return ranges
    }

    private static func walkVoice(
        _ voice: Voice,
        measureIdx: Int,
        measureBase: Int,
        measureDuration: Fraction,
        measures: [Measure],
        division: Int,
        out: inout [OttavaRange],
    ) {
        var runningTick = measureBase
        for element in voice.elements {
            switch element {
            case let .spanner(s) where s.kind == .ottava:
                // End-side placeholders carry only `<prev>` and no
                // payload; skip them so we don't log a phantom range
                // at the close tick. The begin-side has the
                // `<Ottava>` payload and a `<next>` location.
                guard let payload = s.ottava else { break }
                let endTick = computeEndTick(
                    startTick: runningTick,
                    startMeasureIndex: measureIdx,
                    spanner: s,
                    measures: measures,
                    division: division,
                )
                out.append(OttavaRange(
                    startTick: runningTick,
                    endTick: endTick,
                    semitones: payload.subtype.semitones,
                ))
            case let .chord(chord):
                runningTick += chord.duration
                    .resolved(in: measureDuration)
                    .ticks(division: division)
            case let .locationShift(delta):
                runningTick += delta.ticks(division: division)
            default:
                break
            }
        }
    }

    /// End tick = startTick + Σ (next-measures-worth of measure ticks)
    /// + nextFractions delta. MuseScore's `<location>` (the `<next>`
    /// child) is **relative to the begin spanner's own tick**, so we
    /// add the offset directly to `startTick` rather than re-deriving
    /// it from a measure base. Falls back to `startTick + 1` so the
    /// range stays non-empty.
    private static func computeEndTick(
        startTick: Int,
        startMeasureIndex: Int,
        spanner: Spanner,
        measures: [Measure],
        division: Int,
    ) -> Int {
        var measureSpan = 0
        let measureCount = max(0, spanner.nextMeasuresOffset)
        let endIndex = min(measures.count, startMeasureIndex + measureCount)
        if startMeasureIndex < endIndex {
            for i in startMeasureIndex ..< endIndex {
                measureSpan += MidiRenderer.measureTicks(
                    measure: measures[i], division: division,
                )
            }
        }
        let fractionDelta = spanner.nextFractionsOffset?
            .ticks(division: division) ?? 0
        let computed = startTick + measureSpan + fractionDelta
        return max(startTick + 1, computed)
    }
}
