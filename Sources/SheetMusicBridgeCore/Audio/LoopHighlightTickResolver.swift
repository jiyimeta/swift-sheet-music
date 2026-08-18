import SheetMusicAudioCore
import SheetMusicFoundation

/// Maps a tick range onto the score's measure range via
/// `PlaybackTimeline.measureStartTicks`. Pure function; no layout, no handle,
/// so it is testable on the host without a JNI or JavaScript round trip.
package enum LoopHighlightTickResolver {
    package static func measureRange(
        fromTick: Int64,
        toTick: Int64,
        timeline: PlaybackTimeline,
    ) -> (from: Int, toExclusive: Int)? {
        let measureStarts = timeline.measureStartTicks
        guard !measureStarts.isEmpty else { return nil }

        // fromMeasure = largest index where measureStarts[idx] <= fromTick.
        // toMeasureExclusive = first index where measureStarts[idx] >= toTick;
        // when all starts are < toTick, the entire measure list is included.
        var fromMeasure = 0
        var toMeasureExclusive = measureStarts.count
        for idx in measureStarts.indices {
            let start = Int64(measureStarts[idx])
            if start <= fromTick { fromMeasure = idx }
            if start >= toTick {
                toMeasureExclusive = idx
                break
            }
        }
        guard fromMeasure < toMeasureExclusive else { return nil }
        return (fromMeasure, toMeasureExclusive)
    }
}
