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
    public static func metronomeBeats(score: Score) -> [MetronomeBeat] {
        let division = score.division
        let measureCount = score.staves.first?.measures.count ?? 0
        guard measureCount > 0 else { return [] }

        // Per-measure cache: start tick (along voice 0 / staff 0's
        // spine) + active time signature. Same scan used by
        // `PlaybackTimeline.init`.
        var measureStarts = [Int](repeating: 0, count: measureCount)
        var measureTimeSigs = [TimeSignature](
            repeating: TimeSignature(numerator: 4, denominator: 4),
            count: measureCount
        )
        var spineTick = 0
        var currentTimeSig = TimeSignature(numerator: 4, denominator: 4)
        for mi in 0 ..< measureCount {
            measureStarts[mi] = spineTick
            staffLoop: for staff in score.staves {
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
            if let voice0 = score.staves.first?.measures[mi].voices.first {
                for el in voice0.elements {
                    switch el {
                    case let .chord(c):
                        spineTick += c.duration.ticks(division: division)
                    default:
                        break
                    }
                }
            }
        }

        var beats: [MetronomeBeat] = []
        beats.reserveCapacity(measureCount * 4)
        for mi in 0 ..< measureCount {
            let ts = measureTimeSigs[mi]
            // ticks-per-quarter * 4 / denominator. 4/4 → division;
            // 6/8 → division/2; 3/2 → division*2. See
            // `PlaybackTimeline.init` for the same step formula.
            let step = max(1, division * 4 / ts.denominator)
            for i in 0 ..< ts.numerator {
                beats.append(MetronomeBeat(
                    tick: measureStarts[mi] + i * step,
                    isDownbeat: i == 0
                ))
            }
        }
        return beats
    }
}
