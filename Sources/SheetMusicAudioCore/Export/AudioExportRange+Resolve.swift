import Foundation
import SheetMusicCore
import SheetMusicMIDI

extension AudioExportRange {
    /// Resolve to a half-open `[startTick, endTick)` tick range against
    /// the score's `PlaybackTimeline`, with optional `loop` used by
    /// `.currentLoop`.
    ///
    /// Throws `AudioExportError.rangeNotInTimeline` if either cursor in
    /// `.region` / `.regionThroughEnd` can't be resolved, or if the
    /// resulting range would be empty / inverted.
    public func resolveTickRange(
        timeline: PlaybackTimeline,
        loop: LoopRange?,
    ) throws -> (startTick: Int, endTick: Int) {
        switch self {
        case .full:
            return (0, timeline.totalTicks)
        case .currentLoop:
            if let loop {
                return (loop.startTick, loop.endTick)
            }
            return (0, timeline.totalTicks)
        case let .region(from, to):
            guard let sTick = Self.resolveCursorTick(from, in: timeline),
                  let eTick = Self.resolveCursorTick(to, in: timeline),
                  sTick < eTick
            else { throw AudioExportError.rangeNotInTimeline }
            return (sTick, eTick)
        case let .regionThroughEnd(from, last):
            guard let sTick = Self.resolveCursorTick(from, in: timeline),
                  let endTick = timeline.itemEndTicks[last],
                  sTick < endTick
            else { throw AudioExportError.rangeNotInTimeline }
            return (sTick, endTick)
        }
    }

    /// Resolve a `ScoreCursor` to a timeline tick, with fallback for
    /// `.beat` cursors whose tick is occupied by a chord/rest frame
    /// (and therefore has no dedicated `.beat` frame).
    static func resolveCursorTick(
        _ cursor: ScoreCursor,
        in timeline: PlaybackTimeline,
    ) -> Int? {
        if let frame = timeline.frame(forCursor: cursor) {
            return frame.tick
        }
        guard case let .beat(measureIndex: mi, tickInMeasure: tim) = cursor else {
            return nil
        }
        for frame in timeline.frames {
            if case let .beat(measureIndex: fmi, tickInMeasure: ftim) = frame.cursor,
               fmi == mi
            {
                let measureStart = frame.tick - ftim
                let absoluteTick = measureStart + tim
                if absoluteTick >= 0, absoluteTick <= timeline.totalTicks {
                    return absoluteTick
                }
            }
        }
        var measureStartTick: Int?
        for (id, tick) in timeline.itemTicks {
            guard id.measureIndex == mi else { continue }
            if let existing = measureStartTick {
                measureStartTick = min(existing, tick)
            } else {
                measureStartTick = tick
            }
        }
        if let start = measureStartTick {
            let absoluteTick = start + tim
            if absoluteTick >= 0, absoluteTick <= timeline.totalTicks {
                return absoluteTick
            }
        }
        return nil
    }
}
