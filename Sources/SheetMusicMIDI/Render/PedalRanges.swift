import SheetMusicCore
import SheetMusicFoundation

/// One resolved pedal: the original (pre-repeat) tick range during which the sustain pedal is held down. The end tick
/// is half-open like `OttavaRange`: a chord whose onset equals `endTick` is outside the pedal.
struct PedalRange: Equatable {
    let startTick: Int
    let endTick: Int
}

enum PedalRanges {
    /// Walk one voice in original ticks and resolve every sounding pedal begin side into a `PedalRange`.
    ///
    /// A begin side is `kind == .pedal && !isEndMarker`; it sounds unless its payload says `<play>0</play>`
    /// (`lineProperties?.playsBack == false`). `lineProperties` is `nil` when every property is at its default, so a
    /// pedal made in code must sound: the filter is `playsBack ?? true`, never `playsBack == true`. Visibility is not
    /// consulted (MuseScore checks `playSpanner`, not `visible`).
    ///
    /// Known limit: a breath pause earlier in the same bar shifts later events by the pause but not these ticks (the
    /// same approximation `OttavaRanges` makes).
    static func collect(
        voiceIndex: Int,
        staff: Staff,
        division: Int,
        tempoMap: ResolvedTempoMap,
    ) -> [PedalRange] {
        var ranges: [PedalRange] = []
        var measureBase = 0
        let measureDurations = staff.measures.effectiveMeasureDurations()
        for (measureIdx, measure) in staff.measures.enumerated() {
            let measureDuration = measureIdx < measureDurations.count
                ? measureDurations[measureIdx]
                : Fraction(numerator: 4, denominator: 4)
            if voiceIndex < measure.voices.count {
                walkVoice(
                    measure.voices[voiceIndex],
                    measureIdx: measureIdx,
                    measureBase: measureBase,
                    measureDuration: measureDuration,
                    measures: staff.measures,
                    division: division,
                    tempoMap: tempoMap,
                    out: &ranges,
                )
            }
            measureBase += MidiRenderer.measureTicks(
                measure: measure, division: division,
                measureDuration: measureDuration,
                measureIndex: measureIdx, tempoMap: tempoMap,
            )
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
        tempoMap: ResolvedTempoMap,
        out: inout [PedalRange],
    ) {
        var runningTick = measureBase
        for element in voice.elements {
            switch element {
            case let .spanner(s) where s.kind == .pedal && !s.isEndMarker && (s.lineProperties?.playsBack ?? true):
                let endTick = OttavaRanges.computeEndTick(
                    startTick: runningTick,
                    startMeasureIndex: measureIdx,
                    spanner: s,
                    measures: measures,
                    division: division,
                    tempoMap: tempoMap,
                )
                out.append(PedalRange(startTick: runningTick, endTick: endTick))
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
}
