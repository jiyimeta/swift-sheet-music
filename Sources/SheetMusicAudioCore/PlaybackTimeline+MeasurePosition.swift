import SheetMusicCore

/// A place in the score as a measure and an offset into it.
///
/// The coordinate a transport keeps across an edit. A notated tick moves with every measure inserted or removed ahead
/// of it, and a `ScoreItemID` is positional, so neither still names the same place once the score has been edited;
/// "measure 49, at its start" does. `PlaybackEngine.replaceScore(with:)` records its cursor and loop this way before a
/// swap and finds them again in the edited score, and the Android engine's `replaceScore` does the same through
/// `AudioMidiBridge.carriedCursor` / `carriedLoop`.
package struct PlaybackMeasurePosition: Sendable, Equatable {
    package let measureIndex: Int
    package let tickInMeasure: Int

    package init(measureIndex: Int, tickInMeasure: Int) {
        self.measureIndex = measureIndex
        self.tickInMeasure = tickInMeasure
    }
}

/// A loop as the measure positions of its two ends — how a loop is kept across an edit, for the reason
/// `PlaybackMeasurePosition` gives.
package struct PlaybackMeasureLoop: Sendable, Equatable {
    package let start: PlaybackMeasurePosition
    package let end: PlaybackMeasurePosition

    package init(start: PlaybackMeasurePosition, end: PlaybackMeasurePosition) {
        self.start = start
        self.end = end
    }
}

extension PlaybackTimeline {
    /// `tick` as a measure and an offset into it, or nil when the timeline holds no measures.
    package func measurePosition(ofTick tick: Int) -> PlaybackMeasurePosition? {
        guard !measureStartTicks.isEmpty else { return nil }
        // The last measure starting at or before `tick`.
        var lo = 0, hi = measureStartTicks.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if measureStartTicks[mid] <= tick {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return PlaybackMeasurePosition(
            measureIndex: best, tickInMeasure: max(0, tick - measureStartTicks[best]),
        )
    }

    /// The tick `position` names in this timeline, kept inside the score: a measure past the last one becomes the
    /// start of the last, and an offset past the end of its measure becomes that end. Nil when the timeline holds no
    /// measures.
    package func tick(at position: PlaybackMeasurePosition) -> Int? {
        guard !measureStartTicks.isEmpty else { return nil }
        let measureIndex = min(position.measureIndex, measureStartTicks.count - 1)
        let start = measureStartTicks[measureIndex]
        guard measureIndex == position.measureIndex else { return start }
        let end = measureIndex + 1 < measureStartTicks.count
            ? measureStartTicks[measureIndex + 1]
            : max(start, totalTicks)
        return min(start + position.tickInMeasure, end)
    }

    /// Where `cursor` stands in this timeline, as a measure position. Nil when the cursor names no frame here.
    package func measurePosition(ofCursor cursor: ScoreCursor) -> PlaybackMeasurePosition? {
        frame(forCursor: cursor).flatMap { measurePosition(ofTick: $0.tick) }
    }

    /// The cursor of the frame at `position` in this timeline, kept inside the score as `tick(at:)` keeps it.
    package func cursor(at position: PlaybackMeasurePosition) -> ScoreCursor? {
        tick(at: position).flatMap { frame(atTick: $0)?.cursor }
    }

    /// `range` as the measure positions of its ends. Nil when the timeline holds no measures.
    package func measureLoop(of range: LoopRange) -> PlaybackMeasureLoop? {
        guard let start = measurePosition(ofTick: range.startTick),
              let end = measurePosition(ofTick: range.endTick)
        else { return nil }
        return PlaybackMeasureLoop(start: start, end: end)
    }

    /// The loop `loop` names in this timeline. Nil when it no longer spans anything — an edit that shortened the score
    /// can clamp both ends onto the same tick.
    package func loopRange(at loop: PlaybackMeasureLoop) -> LoopRange? {
        guard let start = tick(at: loop.start), let end = tick(at: loop.end), start < end else { return nil }
        return LoopRange(startTick: start, endTick: end)
    }
}
