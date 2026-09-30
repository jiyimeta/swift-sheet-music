import SheetMusicFoundation
import SheetMusicMIDI

/// A `LoopRange` expressed in the transport's own coordinates — shared by every engine that plays the unrolled render.
///
/// `LoopRange` is a region of the SCORE, so it is stored — and handed back to the host — in notated ticks. The
/// transport plays the UNROLLED render, where the same music can sit at several positions (one per pass) and generally
/// none of them is the notated tick. Every comparison against a polled transport position therefore has to use this
/// instead.
package struct TransportLoop: Equatable, Sendable {
    /// Unrolled tick of the loop's start — its FIRST occurrence in playback order, matching the rule the rest of
    /// scheduling follows.
    package let startTick: Int
    /// Exclusive unrolled end. Derived as `startTick + notated span` rather than by looking the notated end tick up on
    /// its own: within one measure-play the region is contiguous and slope-1, whereas the end tick's own first
    /// occurrence can belong to a LATER pass (a loop over a repeated bar would then swallow the repeat's second take).
    package let endTick: Int
    /// The same two bounds on the transport's seconds clock, for a time-based backend. The span is taken from the
    /// notated clock for the same reason: a pass replays its own stretch of the tempo map, so its duration is the
    /// notated one.
    package let startSeconds: TimeInterval
    package let endSeconds: TimeInterval

    package init(startTick: Int, endTick: Int, startSeconds: TimeInterval, endSeconds: TimeInterval) {
        self.startTick = startTick
        self.endTick = endTick
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    /// `loop` projected onto the unrolled transport: its start at the notated start's first occurrence in playback
    /// order, its span the notated span, in ticks and in seconds.
    package static func project(
        _ loop: LoopRange, timeline: PlaybackTimeline, unroll: PlaybackUnroll, unrolledTimeMap: UnrolledTimeMap,
    ) -> TransportLoop {
        let startTick = unroll.firstUnrolledTick(forNotated: loop.startTick)
        let notatedStartSeconds = timeline.seconds(atTick: Double(loop.startTick))
        let notatedEndSeconds = timeline.seconds(atTick: Double(loop.endTick))
        let startSeconds = unrolledTimeMap.unrolledSeconds(fromNotated: notatedStartSeconds)
        return TransportLoop(
            startTick: startTick,
            endTick: startTick + (loop.endTick - loop.startTick),
            startSeconds: startSeconds,
            endSeconds: startSeconds + (notatedEndSeconds - notatedStartSeconds),
        )
    }
}
