/// The notated timeline of a score — where each measure starts in seconds and how a position inside one maps to time —
/// built once from the score's tempo map so a caller that asks many times (a scrub drag asks every frame) pays for the
/// walk once.
///
/// Every tempo-map point counts: a measure is integrated stretch by stretch, each at the tempo in force there, so a
/// ritardando that steps mid-bar, or a plain tempo marking half way through one, lands where `PlaybackTimeline` and the
/// SMF put it. Each repeat is counted once (no expansion). A fermata's hold is part of its measure's span, converted at
/// the tempo in force at the bar's downbeat and spread evenly over the bar's ticks.
public struct NotatedClock: Sendable {
    /// The empty clock: no measures, zero duration.
    public static let empty = NotatedClock(lengths: [], segments: [], spans: [])

    /// A stretch of one measure at a single rate, from `startTick` (inclusive).
    struct Segment: Sendable {
        let startTick: Int
        /// Seconds per tick, the measure's hold share included.
        let secondsPerTick: Double
        /// Seconds from the measure's downbeat to `startTick`.
        let startSeconds: Double
    }

    private let lengths: [Int]
    private let segments: [[Segment]]
    private let spans: [Double]
    private let starts: [Double]
    /// Total notated duration in seconds, each measure counted once.
    public let durationSeconds: Double

    init(lengths: [Int], segments: [[Segment]], spans: [Double]) {
        self.lengths = lengths
        self.segments = segments
        self.spans = spans
        var elapsed = 0.0
        var starts: [Double] = []
        starts.reserveCapacity(spans.count)
        for span in spans {
            starts.append(elapsed)
            elapsed += span
        }
        self.starts = starts
        durationSeconds = elapsed
    }

    /// Number of measures.
    public var measureCount: Int {
        lengths.count
    }

    /// Seconds from the score's start to `measureIndex`'s downbeat; clamped to the first and last measure.
    public func startSeconds(ofMeasure measureIndex: Int) -> Double {
        guard !lengths.isEmpty else { return 0 }
        return starts[min(max(measureIndex, 0), lengths.count - 1)]
    }

    /// Seconds from the score's start to a tick of a measure; both are clamped into the score.
    public func seconds(measureIndex: Int, tickInMeasure: Int) -> Double {
        guard !lengths.isEmpty else { return 0 }
        let measure = min(max(measureIndex, 0), lengths.count - 1)
        guard lengths[measure] > 0 else { return starts[measure] }
        let tick = min(max(tickInMeasure, 0), lengths[measure])
        let segment = segments[measure].last { $0.startTick <= tick } ?? segments[measure][0]
        return starts[measure] + segment.startSeconds + Double(tick - segment.startTick) * segment.secondsPerTick
    }

    /// Inverse of `seconds(measureIndex:tickInMeasure:)`: the `.beat` cursor at `seconds` from the start, clamped to
    /// `0 ... durationSeconds`.
    public func cursor(atSeconds seconds: Double) -> ScoreCursor {
        guard !lengths.isEmpty else { return .beat(measureIndex: 0, tickInMeasure: 0) }
        let target = max(0, seconds)
        // The first measure that has not ended by `target`; the last one when `target` is past the end.
        var low = 0
        var high = lengths.count - 1
        while low < high {
            let mid = (low + high) / 2
            if target < starts[mid] + spans[mid] {
                high = mid
            } else {
                low = mid + 1
            }
        }
        let length = lengths[low]
        guard length > 0 else { return .beat(measureIndex: low, tickInMeasure: 0) }
        let into = min(max(target - starts[low], 0), spans[low])
        let segment = segments[low].last { $0.startSeconds <= into } ?? segments[low][0]
        let tick = Double(segment.startTick) + (into - segment.startSeconds) / segment.secondsPerTick
        return .beat(measureIndex: low, tickInMeasure: min(max(Int(tick.rounded()), 0), length))
    }
}

extension Score {
    /// The notated timeline of this score. Pass `tempoMap` when one is already at hand — building it walks the whole
    /// score — otherwise it is resolved here.
    public func notatedClock(tempoMap: ResolvedTempoMap? = nil) -> NotatedClock {
        let lengths = effectiveMeasureDurations().map { $0.ticks(division: division) }
        guard !lengths.isEmpty else { return .empty }
        let map = tempoMap ?? resolvedTempoMap()
        var holdTicks = [Double](repeating: 0, count: lengths.count)
        for hold in fermataHolds() where holdTicks.indices.contains(hold.measureIndex) {
            holdTicks[hold.measureIndex] += hold.extraTicks
        }
        var segments: [[NotatedClock.Segment]] = []
        var spans: [Double] = []
        segments.reserveCapacity(lengths.count)
        spans.reserveCapacity(lengths.count)
        for (index, length) in lengths.enumerated() {
            let measure = notatedSegments(
                measureIndex: index, length: length, holdTicks: holdTicks[index], map: map,
            )
            segments.append(measure.segments)
            spans.append(measure.span)
        }
        return NotatedClock(lengths: lengths, segments: segments, spans: spans)
    }

    /// Seconds per tick at a quarter-BPM, floored at 1 BPM like the engine's own conversion.
    private func secondsPerTick(beatsPerSecond: Double) -> Double {
        (60.0 / max(1, beatsPerSecond * 60)) / Double(max(1, division))
    }

    /// One measure cut at its tempo-map points. The first stretch runs at the tempo in force at the downbeat; a point
    /// inside the bar starts the next. `holdTicks` become seconds at the downbeat tempo and are spread over the bar.
    private func notatedSegments(
        measureIndex: Int, length: Int, holdTicks: Double, map: ResolvedTempoMap,
    ) -> (segments: [NotatedClock.Segment], span: Double) {
        let downbeat = secondsPerTick(beatsPerSecond: map.beatsPerSecond(atMeasure: measureIndex, tickInMeasure: 0))
        let holdSeconds = holdTicks * downbeat
        guard length > 0 else {
            return ([NotatedClock.Segment(startTick: 0, secondsPerTick: 0, startSeconds: 0)], holdSeconds)
        }
        let holdPerTick = holdSeconds / Double(length)
        var segments = [NotatedClock.Segment(startTick: 0, secondsPerTick: downbeat + holdPerTick, startSeconds: 0)]
        var elapsed = 0.0
        for point in map.points(inMeasure: measureIndex) where point.tickInMeasure > 0 && point.tickInMeasure < length {
            let last = segments[segments.count - 1]
            guard point.tickInMeasure > last.startTick else { continue }
            elapsed += Double(point.tickInMeasure - last.startTick) * last.secondsPerTick
            segments.append(NotatedClock.Segment(
                startTick: point.tickInMeasure,
                secondsPerTick: secondsPerTick(beatsPerSecond: point.beatsPerSecond) + holdPerTick,
                startSeconds: elapsed,
            ))
        }
        let last = segments[segments.count - 1]
        return (segments, elapsed + Double(length - last.startTick) * last.secondsPerTick)
    }
}
