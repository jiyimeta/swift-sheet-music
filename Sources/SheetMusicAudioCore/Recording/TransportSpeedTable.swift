import SheetMusicFoundation

/// A `PlaybackTimeWarp` laid out for the render loop: lookups by binary search over prefix sums of output time, no
/// allocation after `init`.
///
/// The sequencer speed at a transport position is `userRate × stretch(atTransport:)`; a stretch above 1 plays the span
/// faster than notated. Outside every span the stretch is 1.
package struct TransportSpeedTable: Sendable {
    private let starts: [TimeInterval]
    private let ends: [TimeInterval]
    /// Output seconds (at 100 % rate) at each span's start and end.
    private let outputStarts: [TimeInterval]
    private let outputEnds: [TimeInterval]

    /// A nil warp is the identity.
    package init(warp: PlaybackTimeWarp?) {
        let spans = warp?.spans ?? []
        var starts: [TimeInterval] = []
        var ends: [TimeInterval] = []
        var outputStarts: [TimeInterval] = []
        var outputEnds: [TimeInterval] = []
        starts.reserveCapacity(spans.count)
        ends.reserveCapacity(spans.count)
        outputStarts.reserveCapacity(spans.count)
        outputEnds.reserveCapacity(spans.count)
        // Output time the warp has added (or removed) before the current span.
        var shift: TimeInterval = 0
        for span in spans {
            let outputStart = span.start + shift
            let outputEnd = outputStart + span.duration
            starts.append(span.start)
            ends.append(span.end)
            outputStarts.append(outputStart)
            outputEnds.append(outputEnd)
            shift = outputEnd - span.end
        }
        self.starts = starts
        self.ends = ends
        self.outputStarts = outputStarts
        self.outputEnds = outputEnds
    }

    /// `(end − start) / duration` inside a span, 1 outside.
    package func stretch(atTransport t: TimeInterval) -> Double {
        guard let index = Self.lastIndex(in: starts, atOrBefore: t), t < ends[index] else { return 1 }
        return (ends[index] - starts[index]) / (outputEnds[index] - outputStarts[index])
    }

    /// The warped seconds at 100 % rate for transport second `t`; strictly increasing. Identity for `t` before the
    /// first span, including negative `t`.
    package func outputSeconds(atTransport t: TimeInterval) -> TimeInterval {
        guard let index = Self.lastIndex(in: starts, atOrBefore: t) else { return t }
        if t < ends[index] {
            let fraction = (t - starts[index]) / (ends[index] - starts[index])
            return outputStarts[index] + fraction * (outputEnds[index] - outputStarts[index])
        }
        return outputEnds[index] + (t - ends[index])
    }

    /// The inverse of `outputSeconds(atTransport:)`.
    package func transportSeconds(atOutput o: TimeInterval) -> TimeInterval {
        guard let index = Self.lastIndex(in: outputStarts, atOrBefore: o) else { return o }
        if o < outputEnds[index] {
            let fraction = (o - outputStarts[index]) / (outputEnds[index] - outputStarts[index])
            return starts[index] + fraction * (ends[index] - starts[index])
        }
        return ends[index] + (o - outputEnds[index])
    }

    /// The smallest span start or end strictly after `t`, or nil past the last one. The render loop cuts its chunks
    /// there, because the stretch can change.
    package func nextBoundary(after t: TimeInterval) -> TimeInterval? {
        // The first end after `t` and the first start after `t`: spans ascend, so each list is sorted.
        let nextEnd = Self.firstIndex(in: ends, after: t).map { ends[$0] }
        let nextStart = Self.firstIndex(in: starts, after: t).map { starts[$0] }
        switch (nextStart, nextEnd) {
        case let (start?, end?): return min(start, end)
        case let (start?, nil): return start
        case let (nil, end?): return end
        case (nil, nil): return nil
        }
    }

    /// Binary search: the last index whose value is `<= x`, or nil when every value is greater.
    private static func lastIndex(in values: [TimeInterval], atOrBefore x: TimeInterval) -> Int? {
        var lo = 0, hi = values.count - 1, best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if values[mid] <= x {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    /// Binary search: the first index whose value is `> x`, or nil when none is.
    private static func firstIndex(in values: [TimeInterval], after x: TimeInterval) -> Int? {
        var lo = 0, hi = values.count - 1, best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if values[mid] > x {
                best = mid
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        return best
    }
}
