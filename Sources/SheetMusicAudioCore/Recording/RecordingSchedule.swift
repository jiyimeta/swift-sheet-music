import SheetMusicFoundation

/// A stretch of the reference recording, `[sourceStart, sourceEnd)` in reference seconds, that plays from warped output
/// second `outputStart` on (output seconds are score-playback seconds at 100 %, after the time warp). Consecutive
/// segments never touch, so every segment start is a jump the playhead crossfades.
public struct RecordingSegment: Sendable, Equatable {
    public var sourceStart: TimeInterval
    public var sourceEnd: TimeInterval
    public var outputStart: TimeInterval

    public init(sourceStart: TimeInterval, sourceEnd: TimeInterval, outputStart: TimeInterval) {
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.outputStart = outputStart
    }

    /// Output seconds the segment occupies.
    var duration: TimeInterval {
        sourceEnd - sourceStart
    }
}

/// The segment table laid out for the render loop: sorted once in `init`, looked up by binary search, no allocation.
package struct RecordingSchedule: Sendable {
    private let segments: [RecordingSegment]

    package init(segments: [RecordingSegment]) {
        self.segments = segments.sorted { $0.outputStart < $1.outputStart }
    }

    /// The seconds of a track file heard at warped output second `o`, for a track starting `offset` seconds into the
    /// reference time, or nil (silence) outside every segment, at or past a segment's `sourceEnd`, or before the track
    /// itself starts (`reference − offset < 0`).
    func sourceSeconds(atOutput o: TimeInterval, offset: TimeInterval) -> TimeInterval? {
        guard o.isFinite else { return nil }
        // The last segment starting at or before `o`.
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].outputStart <= o { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let segment = segments[low - 1]
        let intoSegment = o - segment.outputStart
        guard intoSegment < segment.duration else { return nil }
        let seconds = segment.sourceStart + intoSegment - offset
        return seconds >= 0 ? seconds : nil
    }
}
