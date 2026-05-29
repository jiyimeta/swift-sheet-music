import Foundation
import SheetMusicCore

/// One resolved breath: the original tick at which the pause is
/// realized, and how many real-time seconds the pause should consume.
///
/// `tick` is the onset tick of the FOLLOWING chord (i.e. the boundary
/// where the silence sits), in original (pre-repeat) tick space — the
/// renderer projects bookends through `playbackPlan` to handle repeats
/// in the same way as `FermataRanges`.
struct BreathPause: Equatable {
    let tick: Int
    let seconds: Double
}

enum BreathRanges {
    /// Walk every voice; for each `.breath` with `pause > 0`, record
    /// the original-tick at which it sits (= the onset tick of the
    /// following chord, or the end of the measure if no next chord)
    /// and its pause duration.
    static func collect(from staff: Staff, division: Int) -> [BreathPause] {
        var out: [BreathPause] = []
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
            for voice in measure.voices {
                out.append(contentsOf: collectInVoice(
                    voice,
                    measureBase: measureBase,
                    measureDuration: measureDuration,
                    division: division,
                ))
            }
            measureBase += mTicks
        }
        return out
    }

    private static func collectInVoice(
        _ voice: Voice,
        measureBase: Int,
        measureDuration: Fraction,
        division: Int,
    ) -> [BreathPause] {
        var runningTick = measureBase
        var out: [BreathPause] = []
        for element in voice.elements {
            switch element {
            case let .chord(chord):
                runningTick += chord.duration
                    .resolved(in: measureDuration)
                    .ticks(division: division)
            case let .locationShift(delta):
                runningTick += delta.ticks(division: division)
            case let .breath(b):
                // Pause is inserted at the current tick — which is
                // the onset tick of the following chord (or the end
                // of the measure if no next chord exists).
                if b.pause > 0 {
                    out.append(BreathPause(
                        tick: runningTick, seconds: b.pause,
                    ))
                }
            default:
                break
            }
        }
        return out
    }
}

extension BreathRanges {
    /// Sweep result. `openEvents` are inserted AFTER the voice walks
    /// (so they sort after same-tick `.tempo` events at the breath
    /// tick), and `closeEvents` are inserted BEFORE the voice walks
    /// (so they sort before same-tick `.tempo` at the restore tick).
    /// Mirrors `FermataRanges.TempoEvents`.
    struct TempoEvents: Equatable {
        var openEvents: [TimedMidiEvent]
        var closeEvents: [TimedMidiEvent]
    }

    /// Convert breath pauses into tempo bookend events. For each
    /// pause at tick T with duration D seconds: insert a slow-tempo
    /// meta event at tick T, and a tempo-restore meta event at tick
    /// T + 1, such that ONE tick at the slow tempo = D seconds of
    /// wall clock. The base tempo for the restore is sampled from
    /// the supplied `TempoTimeline` at tick `T + 1`.
    ///
    /// Math: `microsecondsPerQuarter` is the tempo encoding. At PPQ
    /// = `division`, one tick = `microsPerQuarter / division`
    /// microseconds. For one tick to consume `seconds` seconds:
    /// `microsPerQuarter = seconds * 1_000_000 * division`.
    static func tempoEvents(
        pauses: [BreathPause],
        timeline: TempoTimeline,
        division: Int,
    ) -> TempoEvents {
        guard !pauses.isEmpty else {
            return TempoEvents(openEvents: [], closeEvents: [])
        }
        var open: [TimedMidiEvent] = []
        var close: [TimedMidiEvent] = []
        for pause in pauses {
            let slowMicros = Int(
                (pause.seconds * 1_000_000 * Double(division)).rounded(),
            )
            open.append(TimedMidiEvent(
                tick: pause.tick,
                event: .meta(.tempo(microsecondsPerQuarter: slowMicros)),
            ))
            // Restore to the natural tempo at tick T + 1. We sample
            // the timeline at T + 1 so any tempo change that lands
            // exactly at the breath tick (e.g. a `<Tempo>` element
            // sitting just before the breath in voice order) is
            // honoured in the restore.
            let baseBps = timeline.bps(at: pause.tick + 1)
            let restoreMicros = Int((1_000_000.0 / baseBps).rounded())
            close.append(TimedMidiEvent(
                tick: pause.tick + 1,
                event: .meta(.tempo(microsecondsPerQuarter: restoreMicros)),
            ))
        }
        return TempoEvents(openEvents: open, closeEvents: close)
    }
}
