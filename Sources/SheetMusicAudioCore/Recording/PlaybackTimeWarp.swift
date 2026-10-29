import SheetMusicFoundation

/// How long each stretch of the transport's own clock must last, so a host can make the score's playback follow an
/// external timing (a recording whose performer did not keep the notated tempo).
///
/// The transport plays the score's SMF at its notated tempo; it knows nothing of the external timing. A warp is a list
/// of spans on that clock, each saying "these transport seconds must take this long at 100 % rate". Outside the spans
/// transport seconds pass 1:1. An empty warp is the identity.
///
/// A span's stretch, `(end − start) / duration`, is the speed the transport plays it at relative to the notated tempo,
/// and must lie in `0.02 ... 50`: from a fiftieth of the notated speed to fifty times it, far outside any performance.
/// A stretch near zero or in the thousands comes from a misplaced beat, not a player: the transport would crawl until a
/// backend's speed floor (0.01) parted it from the warp, or leap whole beats per synthesizer block.
public struct PlaybackTimeWarp: Sendable, Equatable {
    /// One stretch of the transport's clock and the time it must last.
    public struct Span: Sendable, Equatable {
        /// Transport seconds where the span begins.
        public var start: TimeInterval
        /// Transport seconds where the span ends; greater than `start`.
        public var end: TimeInterval
        /// Seconds the span lasts at 100 % rate; greater than zero.
        public var duration: TimeInterval

        public init(start: TimeInterval, end: TimeInterval, duration: TimeInterval) {
            self.start = start
            self.end = end
            self.duration = duration
        }
    }

    /// The stretches a span may have (see the type's documentation).
    static let stretchRange: ClosedRange<Double> = 0.02 ... 50

    /// Ascending and non-overlapping (touching is allowed).
    package private(set) var spans: [Span]

    /// Throws `.invalidSpan` for a span with a non-finite field, `end <= start`, `duration <= 0` or a stretch outside
    /// `0.02 ... 50`, and `.notAscending` when a span starts before the previous one ends. Both carry the offending
    /// span's index.
    public init(spans: [Span]) throws(PlaybackTimeWarpError) {
        var previousEnd = -TimeInterval.infinity
        for (index, span) in spans.enumerated() {
            guard span.start.isFinite, span.end.isFinite, span.duration.isFinite,
                  span.end > span.start, span.duration > 0,
                  Self.stretchRange.contains((span.end - span.start) / span.duration)
            else { throw .invalidSpan(index: index) }
            guard span.start >= previousEnd else { throw .notAscending(index: index) }
            previousEnd = span.end
        }
        self.spans = spans
    }
}

public enum PlaybackTimeWarpError: Error, Equatable {
    /// The span at `index` starts before the previous span ends.
    case notAscending(index: Int)
    /// The span at `index` has a non-finite field, an `end` not after its `start`, a `duration` not above zero, or a
    /// stretch, `(end − start) / duration`, outside `0.02 ... 50`.
    case invalidSpan(index: Int)
}
