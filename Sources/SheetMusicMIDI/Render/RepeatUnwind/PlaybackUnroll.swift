import SheetMusicCore
import SheetMusicFoundation

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
    ///
    /// Public so a caller holding a NOTATED tick↔seconds clock (i.e. a
    /// `PlaybackTimeline`) can integrate the measure-plays into an
    /// unrolled SECONDS axis — the projection a time-based transport
    /// needs to map its own position back onto notated frames. The tick
    /// map here is slope-1 per span, but the seconds map is not: a
    /// repeated measure re-runs its own tempo, so the durations have to
    /// be accumulated span by span.
    public struct Span: Equatable, Sendable {
        public var unrolledStart: Int
        public var notatedStart: Int
        /// The measure-play's length in ticks (== the notated measure's
        /// `tickSpan`). Lets `unrolledTicks(forNotated:)` test whether a
        /// notated tick falls inside `[notatedStart, notatedStart + notatedLength)`.
        public var notatedLength: Int
    }

    /// Sorted ascending by `unrolledStart`. Empty for `identity`.
    public let spans: [Span]
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

    /// Every unrolled occurrence of a NOTATED tick — the inverse of
    /// `notatedTick(fromUnrolled:)`, which only returns one (the
    /// first-occurrence) direction of the map. A tick inside a measure
    /// that is played twice (a repeat) or replayed by a jump maps to
    /// TWO OR MORE unrolled ticks, one per pass, sorted ascending
    /// (`spans` is itself sorted by `unrolledStart`, which for a
    /// well-formed plan is playback order). Used to project the
    /// NOTATED body metronome beats (`PlaybackTimeline.metronomeBeats`)
    /// onto the UNROLLED sequencer timeline so the click track doesn't
    /// go silent past the first pass.
    ///
    /// Returns `[notated]` (identity) for a plan-less score — matching
    /// `notatedTick(fromUnrolled:)`'s pass-through behavior — so a
    /// score without a computed repeat plan never silently drops a
    /// beat. Returns `[]` when `notated` falls inside no span's
    /// `[notatedStart, notatedStart + notatedLength)` range (e.g. past
    /// the last notated measure).
    public func unrolledTicks(forNotated notated: Int) -> [Int] {
        guard !spans.isEmpty else { return [notated] }
        var result: [Int] = []
        for span in spans
            where notated >= span.notatedStart
            && notated < span.notatedStart + span.notatedLength
        {
            result.append(span.unrolledStart + (notated - span.notatedStart))
        }
        return result
    }

    /// The single UNROLLED tick a scheduling move should target for a NOTATED
    /// score tick: its FIRST occurrence in playback order.
    ///
    /// The read direction (`notatedTick(fromUnrolled:)`) is a function; this
    /// one is not — a bar inside a repeat sits at one unrolled tick per pass,
    /// and `unrolledTicks(forNotated:)` returns them all. Seek, play-from and
    /// the loop wrap all target the first, which is the rule the rest of
    /// scheduling already follows.
    ///
    /// A tick that falls inside no span extrapolates off the LAST measure-play
    /// rather than failing: that is the end-of-score offset tick a half-open
    /// region hands in (a loop's exclusive end, `totalTicks`), which by
    /// construction has no frame of its own. This mirrors
    /// `notatedTick(fromUnrolled:)`'s own last-segment fallthrough in the
    /// opposite direction. Identity for a plan-less score, so a caller that
    /// routes every scheduling tick through this is unchanged on any score
    /// without a repeat.
    ///
    /// Both platforms call this rather than restating it: the Apple engine
    /// through `PlaybackEngine`, the Android engine through the
    /// `nativeUnrolledTickForNotated` JNI entry point.
    public func firstUnrolledTick(forNotated notated: Int) -> Int {
        if let first = unrolledTicks(forNotated: notated).first { return first }
        guard let last = spans.last else { return notated }
        return last.unrolledStart + (notated - last.notatedStart)
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
            let measureTickSpan = navigation.measures[entry.measureIndex].tickSpan
            spans.append(PlaybackUnroll.Span(
                unrolledStart: entry.tickOffset,
                notatedStart: notatedBases[entry.measureIndex],
                notatedLength: measureTickSpan,
            ))
            total = max(total, entry.tickOffset + measureTickSpan)
        }
        return PlaybackUnroll(spans: spans, totalUnrolledTicks: total)
    }
}
