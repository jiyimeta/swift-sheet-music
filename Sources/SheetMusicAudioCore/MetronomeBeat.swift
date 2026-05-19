import Foundation
import SheetMusicCore

/// One metronome tick — the metric beat at which the click should
/// sound, with a flag for the strong (downbeat) accent.
public struct MetronomeBeat: Sendable, Equatable {
    /// Absolute tick on the score's `division`-per-quarter timeline.
    public let tick: Int
    public let isDownbeat: Bool
}

extension PlaybackTimeline {
    /// Beat schedule for the score, suitable for driving a
    /// MuseScore-style metronome. Beats land on every metric beat
    /// (denominator-derived step — quarter in 3/4 or 4/4, eighth in
    /// 6/8, etc.) regardless of whether a chord/rest happens to share
    /// the tick. The first beat of each measure is the downbeat.
    ///
    /// Mirrors `mu::engraving::PlaybackEventsRenderer::renderMetronome`
    /// in MuseScore (`src/engraving/playback/playbackeventsrenderer.cpp`)
    /// for the simple-meter case: one beat per denominator unit, with
    /// the first marked as `BeatType::DOWNBEAT`.
    public static func metronomeBeats(score: Score) -> [MetronomeBeat] { // swiftlint:disable:this function_body_length
        let division = score.division
        let measures = score.parts.first?.staves.first?.measures ?? []
        let measureCount = measures.count
        guard measureCount > 0 else { return [] }

        // Per-measure cache: start tick (along voice 0 / staff 0's
        // spine), active time signature, and spine length consumed
        // by the measure. Same scan used by `PlaybackTimeline.init`.
        var measureStarts = [Int](repeating: 0, count: measureCount)
        var measureLengths = [Int](repeating: 0, count: measureCount)
        var measureTimeSigs = [TimeSignature](
            repeating: TimeSignature(numerator: 4, denominator: 4),
            count: measureCount,
        )
        let measureDurations = measures.effectiveMeasureDurations()
        var spineTick = 0
        var currentTimeSig = TimeSignature(numerator: 4, denominator: 4)
        for mi in 0 ..< measureCount {
            measureStarts[mi] = spineTick
            staffLoop: for entry in score.allStaves {
                let staff = entry.staff
                guard mi < staff.measures.count else { continue }
                for el in staff.measures[mi].voices.first?.elements ?? [] {
                    switch el {
                    case let .timeSignature(ts):
                        currentTimeSig = ts
                        break staffLoop
                    case .chord:
                        break staffLoop
                    default:
                        break
                    }
                }
            }
            measureTimeSigs[mi] = currentTimeSig
            let measureDuration = mi < measureDurations.count
                ? measureDurations[mi]
                : Fraction(numerator: 4, denominator: 4)
            var measureLen = 0
            if let voice0 = measures[mi].voices.first {
                for el in voice0.elements {
                    switch el {
                    case let .chord(c):
                        measureLen += c.duration
                            .resolved(in: measureDuration)
                            .ticks(division: division)
                    default:
                        break
                    }
                }
            }
            measureLengths[mi] = measureLen
            spineTick += measureLen
        }

        var beats: [MetronomeBeat] = []
        beats.reserveCapacity(measureCount * 4)
        for mi in 0 ..< measureCount {
            let ts = measureTimeSigs[mi]
            // ticks-per-quarter * 4 / denominator. 4/4 → division;
            // 6/8 → division/2; 3/2 → division*2. See
            // `PlaybackTimeline.init` for the same step formula.
            let step = max(1, division * 4 / ts.denominator)
            // Anacrusis / pickup measures (`Measure.irregular` or
            // `actualLength` shorter than the nominal time signature)
            // produce fewer than `numerator` beats and start without
            // a downbeat — matching MuseScore's metronome convention.
            let measureLen = measureLengths[mi]
            let isIrregular = measures[mi].irregular
            for i in 0 ..< ts.numerator {
                let offset = i * step
                if offset >= measureLen { break }
                beats.append(MetronomeBeat(
                    tick: measureStarts[mi] + offset,
                    isDownbeat: i == 0 && !isIrregular,
                ))
            }
        }
        return beats
    }
}
