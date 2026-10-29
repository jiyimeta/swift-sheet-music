import Foundation
import SheetMusicAudioCore
import SheetMusicCore

/// The count an export puts in front of the music — the one `play(from:in:countIn:)` plays live from the same start.
///
/// Both export pipelines read it: the AUMIDISynth one prepends `plan`'s clicks to its sequence
/// (`PreRollSequenceAssembler.assemble`, as `buildCountInSequencer` does live), the backend one loads them onto the
/// metronome transport and holds the score for `preRollSeconds` (as `startBackendCountIn` does live). Either way the
/// file grows by `preRollSeconds` at the export's rate — on a backend following an alignment, at the speed of the
/// measure it counts into (`exportFrameCount`), as live.
extension PlaybackEngine {
    struct ExportCountIn: Equatable {
        /// The count-in schedule at the export's start.
        let plan: CountInBeats.Result
        /// The score tick the count leads into — the export range's start.
        let baseTick: Int
        /// How long the count lasts on the sequence clock (rate 1), at the rounded tempo its sequence is seeded with.
        let preRollSeconds: TimeInterval
        /// How far ahead of the score transport the backend's count-in metronome sequence runs: where `baseTick`
        /// sits on the metronome's clock, minus where it sits on the score's unrolled one.
        let metronomeOffsetSeconds: TimeInterval
    }

    /// The count for an export starting at `startTick`, or `nil` when that start has none
    /// (`CountInBeats.compute` returns nil) — such an export renders as if `countIn` were false.
    ///
    /// `metronomeOffsetSeconds` is the live rule from `startBackendCountIn`: both backend transports run on the
    /// unrolled render's seconds, so the start's notated seconds are projected onto that clock before they are
    /// subtracted.
    static func exportCountIn(
        score: Score, timeline: PlaybackTimeline, unrolled: UnrolledTimeMap, startTick: Int,
    ) -> ExportCountIn? {
        guard let plan = CountInBeats.compute(
            score: score, startCursor: timeline.frame(atTick: startTick)?.cursor,
        ) else { return nil }
        let preRollSeconds = plan.preRollSeconds(division: timeline.division)
        return ExportCountIn(
            plan: plan,
            baseTick: startTick,
            preRollSeconds: preRollSeconds,
            metronomeOffsetSeconds: preRollSeconds - unrolled.unrolledSeconds(
                fromNotated: timeline.seconds(atTick: Double(startTick)),
            ),
        )
    }
}
