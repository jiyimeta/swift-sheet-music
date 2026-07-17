import Foundation
import SheetMusicCore

/// Maps the sequencer's UNROLLED tick space — the coordinates of the
/// SMF `MidiRenderer.render(score:)` produces, where repeats and
/// jumps are expanded — back to NOTATED score ticks, the coordinates
/// `PlaybackTimeline` frames use. Swift analog of MuseScore's
/// `RepeatList::utick2tick` (repeatlist.cpp:255-274).
///
/// The map is piecewise linear: one span per measure-play. Cursor /
/// time READ paths translate through it; scheduling (loop wrap, seek,
/// play-from) stays in first-occurrence coordinates.
public struct PlaybackUnroll: Sendable, Equatable {
    /// One measure-play: `[unrolledStart, unrolledStart + span)` in
    /// the SMF maps to `notatedStart + offset` in the score.
    struct Span: Equatable {
        var unrolledStart: Int
        var notatedStart: Int
    }

    /// Sorted ascending by `unrolledStart`.
    let spans: [Span]
    /// Total length of the unrolled sequence in ticks (end of the
    /// last measure-play). 0 for `identity`.
    public let totalUnrolledTicks: Int

    /// Pass-through map (score without a computed plan).
    public static let identity = PlaybackUnroll(spans: [], totalUnrolledTicks: 0)

    /// The notated tick a raw unrolled tick corresponds to. Negative
    /// input clamps to 0 (utick2tick, repeatlist.cpp:261-263); input
    /// past the last span extrapolates from it (repeatlist.cpp:266,
    /// last-segment fallthrough).
    public func notatedTick(fromUnrolled unrolled: Int) -> Int {
        guard !spans.isEmpty else { return unrolled }
        if unrolled < 0 { return 0 }
        // Binary search: last span with unrolledStart <= unrolled.
        var lo = 0, hi = spans.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].unrolledStart <= unrolled {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let span = spans[best]
        return span.notatedStart + (unrolled - span.unrolledStart)
    }

    /// Fractional-tick variant for continuous readers
    /// (`PlaybackEngine.currentTimeSecondsContinuous`). The map is
    /// piecewise linear with slope 1, so the fractional part carries
    /// over unchanged within a span.
    public func notatedTick(fromUnrolled unrolled: Double) -> Double {
        guard !spans.isEmpty else { return unrolled }
        if unrolled < 0 { return 0 }
        let floorTick = Int(unrolled.rounded(.down))
        let base = notatedTick(fromUnrolled: floorTick)
        return Double(base) + (unrolled - Double(floorTick))
    }
}

extension MidiRenderer {
    /// The unrolled→notated tick map for `score`, computed from the
    /// same score-global plan `render(score:)` uses — so it matches
    /// the SMF a sequencer is playing bit-for-bit in time.
    public static func playbackUnroll(score: Score) -> PlaybackUnroll {
        let navigation = ScoreNavigation(score: score)
        let plan = RepeatUnwinder.plan(navigation: navigation)
        var notatedBases: [Int] = []
        var accumulated = 0
        for facts in navigation.measures {
            notatedBases.append(accumulated)
            accumulated += facts.tickSpan
        }
        var spans: [PlaybackUnroll.Span] = []
        var total = 0
        for entry in plan {
            spans.append(PlaybackUnroll.Span(
                unrolledStart: entry.tickOffset,
                notatedStart: notatedBases[entry.measureIndex],
            ))
            total = max(
                total,
                entry.tickOffset + navigation.measures[entry.measureIndex].tickSpan,
            )
        }
        return PlaybackUnroll(spans: spans, totalUnrolledTicks: total)
    }
}
