import Foundation
import SheetMusicMIDI

/// Projects a position on the UNROLLED transport's seconds clock onto the NOTATED
/// timeline's seconds clock.
///
/// A time-based backend (SwiftySynth) plays `MidiRenderer.render`'s unrolled SMF — repeats
/// and jumps expanded — and reports its position in that sequence's seconds. Every cursor /
/// elapsed-time read, though, is a lookup into a notated `PlaybackTimeline`. Handing the raw
/// unrolled seconds to `PlaybackTimeline.frame(atTime:)` is wrong twice over on a score with
/// a repeat: from the second measure-play onward the lookup runs a full measure-play ahead of
/// the audio, and once the unrolled position passes the notated duration it saturates on the
/// last frame and stops moving. (The AUMIDISynth path is immune — it polls unrolled TICKS and
/// runs them through `PlaybackUnroll.notatedTick(fromUnrolled:)`.)
///
/// `PlaybackUnroll` alone can't do this: its map is slope-1 in TICK space, but not in seconds.
/// A repeated measure replays its own stretch of the tempo map, so each measure-play's
/// duration has to be integrated separately and accumulated. That's what this builds — one
/// cumulative start-time per measure-play, computed once at prepare time.
public struct UnrolledTimeMap: Sendable {
    /// Cumulative unrolled start time of each measure-play, parallel to `unroll.spans`.
    private let unrolledStartSeconds: [TimeInterval]
    /// Notated start time of each measure-play, parallel to `unroll.spans`.
    private let notatedStartSeconds: [TimeInterval]
    private let spans: [PlaybackUnroll.Span]

    /// Pass-through map, for a score with no repeat plan (`PlaybackUnroll.identity`) — the
    /// unrolled and notated clocks are the same, so nothing needs projecting.
    public static let identity = UnrolledTimeMap(
        unrolledStartSeconds: [], notatedStartSeconds: [], spans: [],
    )

    private init(
        unrolledStartSeconds: [TimeInterval],
        notatedStartSeconds: [TimeInterval],
        spans: [PlaybackUnroll.Span],
    ) {
        self.unrolledStartSeconds = unrolledStartSeconds
        self.notatedStartSeconds = notatedStartSeconds
        self.spans = spans
    }

    /// Integrate `unroll`'s measure-plays against `timeline`'s notated tick→seconds clock.
    /// Each span's duration is the notated time it covers; laying those end to end gives the
    /// unrolled seconds axis the transport actually runs on.
    public init(unroll: PlaybackUnroll, timeline: PlaybackTimeline) {
        let spans = unroll.spans
        guard !spans.isEmpty else {
            self = .identity
            return
        }
        var unrolledStarts: [TimeInterval] = []
        var notatedStarts: [TimeInterval] = []
        unrolledStarts.reserveCapacity(spans.count)
        notatedStarts.reserveCapacity(spans.count)
        var cumulative: TimeInterval = 0
        for span in spans {
            let start = timeline.seconds(atTick: Double(span.notatedStart))
            let end = timeline.seconds(
                atTick: Double(span.notatedStart + span.notatedLength),
            )
            unrolledStarts.append(cumulative)
            notatedStarts.append(start)
            // `max(0, …)` is defense in depth: a well-formed span has positive duration, and a
            // degenerate one must not make the axis run backwards (which would break the
            // binary search below).
            cumulative += max(0, end - start)
        }
        self.init(
            unrolledStartSeconds: unrolledStarts,
            notatedStartSeconds: notatedStarts,
            spans: spans,
        )
    }

    /// The notated time corresponding to `unrolledSeconds` on the transport's clock.
    ///
    /// Clamps below zero to zero. Past the final measure-play it extrapolates from that
    /// play — mirroring `PlaybackUnroll.notatedTick(fromUnrolled:)`'s last-segment
    /// fallthrough — so a caller polling slightly past the end still gets a monotonically
    /// advancing value instead of a frozen one.
    public func notatedSeconds(fromUnrolled unrolledSeconds: TimeInterval) -> TimeInterval {
        guard !spans.isEmpty else { return unrolledSeconds }
        if unrolledSeconds <= 0 { return 0 }
        // Binary search: last measure-play starting at or before `unrolledSeconds`.
        var lo = 0, hi = unrolledStartSeconds.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if unrolledStartSeconds[mid] <= unrolledSeconds {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let offset = unrolledSeconds - unrolledStartSeconds[best]
        return notatedStartSeconds[best] + offset
    }

    /// The unrolled time of a notated position's FIRST occurrence — the inverse direction,
    /// restricted the same way `PlaybackUnroll` restricts scheduling ("loop wrap, seek,
    /// play-from stay in first-occurrence coordinates"). A notated instant inside a repeated
    /// measure has one unrolled time per pass; this returns the earliest.
    ///
    /// Needed to anchor a count-in: the pre-roll-shifted SMF is still the unrolled render, so
    /// converting the play's notated start tick into unrolled time is what lets elapsed body
    /// seconds be added in the right coordinate space. Falls back to the input when no span
    /// covers it (identity map, or a position past the last measure-play).
    public func unrolledSeconds(fromNotated notatedSeconds: TimeInterval) -> TimeInterval {
        guard !spans.isEmpty else { return notatedSeconds }
        if notatedSeconds <= 0 { return 0 }
        for index in spans.indices {
            let start = notatedStartSeconds[index]
            let end = index + 1 < spans.count
                // A span's notated end is its own start plus its duration; derive it from the
                // unrolled axis, which was built from exactly those durations.
                ? start + (unrolledStartSeconds[index + 1] - unrolledStartSeconds[index])
                : .infinity
            if notatedSeconds >= start, notatedSeconds < end {
                return unrolledStartSeconds[index] + (notatedSeconds - start)
            }
        }
        return notatedSeconds
    }
}
