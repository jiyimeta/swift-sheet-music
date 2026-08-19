import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicMIDI

/// The projection a browser host needs between the clock its player reports and
/// the notated score.
///
/// Android does this in ticks — `nativeFrameAtTick` / `nativeSecondsAtTick` /
/// `nativeUnrolledTickForNotated` — because the FluidSynth player reports an
/// UNROLLED SMF tick. A Web Audio sequencer reports seconds instead, and
/// `UnrolledTimeMap` already speaks seconds on both sides, so the whole tick
/// round trip collapses into the two conversions below.
///
/// **"player seconds" are UNROLLED** — the coordinates of the SMF
/// `AudioMidiBridge.renderMidi` produced, with repeats and jumps expanded.
/// **"notated seconds" are the score's own.** The two are equal on any score
/// without a repeat plan, which is exactly why a fixture *with* a repeat is
/// required to test this: without one, a no-op implementation passes.
package struct PlaybackClock {
    private let timeline: PlaybackTimeline
    private let unrolledTimeMap: UnrolledTimeMap
    private let unroll: PlaybackUnroll
    /// Player-seconds offset at which each of `unroll.spans` begins, accumulated
    /// span by span.
    ///
    /// `UnrolledTimeMap` builds the same axis internally but does not expose it,
    /// and its public inverse (`unrolledSeconds(fromNotated:)`) deliberately
    /// answers with a notated position's FIRST occurrence. That is the right
    /// answer for a seek and the wrong one for "where on the player's clock is
    /// THIS measure-play", which is what `playerSecondsForUnrolledTick` needs —
    /// a beat in a repeat's second pass would otherwise report the first pass's
    /// time. Hence the second copy of the accumulation.
    private let spanStartPlayerSeconds: [TimeInterval]
    private let accumulatedPlayerSeconds: TimeInterval

    package init(score: Score) {
        let timeline = PlaybackTimeline(score: score)
        let unroll = MidiRenderer.playbackUnroll(score: score)
        self.timeline = timeline
        self.unroll = unroll
        unrolledTimeMap = UnrolledTimeMap(unroll: unroll, timeline: timeline)

        var starts: [TimeInterval] = []
        starts.reserveCapacity(unroll.spans.count)
        var cumulative: TimeInterval = 0
        for span in unroll.spans {
            starts.append(cumulative)
            let start = timeline.seconds(atTick: Double(span.notatedStart))
            let end = timeline.seconds(
                atTick: Double(span.notatedStart + span.notatedLength),
            )
            // `max(0, …)` mirrors UnrolledTimeMap: a degenerate span must not
            // make the axis run backwards, which would break the search below.
            cumulative += max(0, end - start)
        }
        spanStartPlayerSeconds = starts
        accumulatedPlayerSeconds = cumulative
    }

    package var totalNotatedSeconds: TimeInterval {
        timeline.totalSeconds
    }

    /// The length of the sequence the synth actually plays — longer than
    /// `totalNotatedSeconds` on any score with repeats.
    package var totalPlayerSeconds: TimeInterval {
        unroll.spans.isEmpty ? timeline.totalSeconds : accumulatedPlayerSeconds
    }

    package var measureCount: Int {
        timeline.measureStartTicks.count
    }

    /// Ticks per quarter note.
    package var division: Int {
        timeline.division
    }

    package func notatedSeconds(fromPlayer playerSeconds: TimeInterval) -> TimeInterval {
        guard playerSeconds.isFinite, playerSeconds > 0 else { return 0 }
        return unrolledTimeMap.notatedSeconds(fromUnrolled: playerSeconds)
    }

    /// The FIRST player position a notated instant sounds at — the coordinates
    /// a seek, a play-from and a loop wrap all work in, matching the
    /// restriction `PlaybackUnroll` puts on scheduling.
    package func playerSeconds(fromNotated notatedSeconds: TimeInterval) -> TimeInterval {
        guard notatedSeconds.isFinite, notatedSeconds > 0 else { return 0 }
        return unrolledTimeMap.unrolledSeconds(fromNotated: notatedSeconds)
    }

    package func frame(atPlayerSeconds playerSeconds: TimeInterval) -> PlaybackTimeline.Frame? {
        timeline.frame(atTime: notatedSeconds(fromPlayer: playerSeconds))
    }

    /// The player position measure `measureIndex` starts at, or `nil` when the
    /// index is outside the score.
    package func playerSeconds(atMeasureIndex measureIndex: Int) -> TimeInterval? {
        guard let tick = measureStartTick(measureIndex) else { return nil }
        return playerSeconds(fromNotated: timeline.seconds(atTick: Double(tick)))
    }

    /// The measure sounding at `playerSeconds`, or `nil` for a score with no
    /// measures. Clamps rather than failing at the ends: a position past the
    /// last measure start belongs to the last measure.
    package func measureIndex(atPlayerSeconds playerSeconds: TimeInterval) -> Int? {
        let starts = timeline.measureStartTicks
        guard !starts.isEmpty else { return nil }
        guard let frame = frame(atPlayerSeconds: playerSeconds) else { return 0 }
        var result = 0
        for (index, start) in starts.enumerated() where start <= frame.tick {
            result = index
        }
        return result
    }

    /// The player position `cursor` sounds at, or `nil` when the timeline has no
    /// frame for it.
    ///
    /// First occurrence, like every other seek target: a cursor inside a
    /// repeated measure has one player position per pass, and scheduling is
    /// restricted to the earliest.
    package func playerSeconds(atCursor cursor: ScoreCursor) -> TimeInterval? {
        guard let frame = timeline.frame(forCursor: cursor) else { return nil }
        return playerSeconds(fromNotated: frame.timeSeconds)
    }

    /// The cursor sounding at a player position — what a count-in starting
    /// anywhere but a downbeat needs.
    package func cursor(atPlayerSeconds playerSeconds: TimeInterval) -> ScoreCursor? {
        frame(atPlayerSeconds: playerSeconds)?.cursor
    }

    /// A cursor parked on measure `measureIndex`'s downbeat, for the count-in
    /// schedule (`CountInBeats.compute(score:startCursor:)`).
    package func cursorAtMeasureStart(_ measureIndex: Int) -> ScoreCursor? {
        guard measureIndex >= 0, measureIndex < timeline.measureStartTicks.count else {
            return nil
        }
        return .beat(measureIndex: measureIndex, tickInMeasure: 0)
    }

    /// The notated start tick of `measureIndex`, or `nil` when out of range.
    package func measureStartTick(_ measureIndex: Int) -> Int? {
        let starts = timeline.measureStartTicks
        guard measureIndex >= 0, measureIndex < starts.count else { return nil }
        return starts[measureIndex]
    }

    /// The UNROLLED transport tick a NOTATED tick sits at — the write direction,
    /// still needed because `renderCountInMetronomeMidi` anchors on a base tick.
    package func unrolledTick(fromNotatedTick notatedTick: Int) -> Int {
        unroll.firstUnrolledTick(forNotated: notatedTick)
    }

    /// Player seconds at an UNROLLED tick — the coordinates
    /// `PlaybackTimeline.unrolledMetronomeBeats` reports in.
    ///
    /// Resolved against the measure-play the tick falls in rather than through
    /// `playerSeconds(fromNotated:)`: that one answers with a notated instant's
    /// first occurrence, so every beat of a repeat's second pass would come back
    /// carrying the first pass's time and the beat indicator would stall.
    package func playerSecondsForUnrolledTick(_ unrolledTick: Int) -> TimeInterval {
        guard unrolledTick > 0 else { return 0 }
        let spans = unroll.spans
        guard !spans.isEmpty else {
            return timeline.seconds(atTick: Double(unrolledTick))
        }
        // Binary search: last measure-play starting at or before `unrolledTick`.
        var lo = 0
        var hi = spans.count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].unrolledStart <= unrolledTick {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let span = spans[best]
        let notatedTick = span.notatedStart + (unrolledTick - span.unrolledStart)
        let elapsed = timeline.seconds(atTick: Double(notatedTick))
            - timeline.seconds(atTick: Double(span.notatedStart))
        return spanStartPlayerSeconds[best] + max(0, elapsed)
    }
}
