import SheetMusicCore
import SheetMusicFoundation
import SheetMusicMIDI

/// One measure as playback plays it: repeats and jumps unrolled, on the transport's own (unrolled SMF) seconds at the
/// notated tempo. A host that aligns something to the score by measure and beat reads this to turn its alignment into
/// a time warp over the transport clock.
public struct PlayedMeasure: Sendable, Equatable {
    /// The notated system measure.
    public let measureIndex: Int
    /// 1-based: the n-th time playback reaches `measureIndex`.
    public let pass: Int
    /// Transport (unrolled SMF) seconds at the notated tempo.
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    /// Transport seconds of each click beat in the measure, ascending.
    public let beatSeconds: [TimeInterval]
    /// The measure's actual length divided by the click's beat step (0.5 for an eighth pickup in 4/4).
    public let lengthInBeats: Double

    /// A measure-play as `PlayedMeasures.make(score:)` reports one; a host's tests build their own with it.
    public init(
        measureIndex: Int, pass: Int, startSeconds: TimeInterval, endSeconds: TimeInterval,
        beatSeconds: [TimeInterval], lengthInBeats: Double,
    ) {
        self.measureIndex = measureIndex
        self.pass = pass
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.beatSeconds = beatSeconds
        self.lengthInBeats = lengthInBeats
    }
}

public enum PlayedMeasures {
    /// Every measure-play of `score` in playback order.
    public static func make(score: Score) -> [PlayedMeasure] {
        let timeline = PlaybackTimeline(score: score)
        let unroll = MidiRenderer.playbackUnroll(score: score)
        return make(
            score: score,
            timeline: timeline,
            unroll: unroll,
            unrolledTimeMap: UnrolledTimeMap(unroll: unroll, timeline: timeline),
        )
    }

    package static func make(
        score: Score,
        timeline: PlaybackTimeline,
        unroll: PlaybackUnroll,
        unrolledTimeMap: UnrolledTimeMap,
    ) -> [PlayedMeasure] {
        let starts = timeline.measureStartTicks
        guard !starts.isEmpty else { return [] }

        // A score with no repeat plan plays each notated measure once, in order, on the notated clock.
        let plays: [(measureIndex: Int, notatedStart: Int, notatedLength: Int, startSeconds: TimeInterval)]
        if unroll.spans.isEmpty {
            plays = starts.indices.map { index in
                let end = index + 1 < starts.count ? starts[index + 1] : max(timeline.totalTicks, starts[index])
                return (index, starts[index], end - starts[index], timeline.seconds(atTick: Double(starts[index])))
            }
        } else {
            plays = zip(unroll.spans, unrolledTimeMap.spanStartSeconds).map {
                ($0.measureIndex, $0.notatedStart, $0.notatedLength, $1)
            }
        }

        let grid = PlaybackTimeline.metronomeGrid(score: score)
        var passes: [Int: Int] = [:]
        var result: [PlayedMeasure] = []
        result.reserveCapacity(plays.count)
        for (measureIndex, notatedStart, notatedLength, startSeconds) in plays {
            guard grid.stepTicks.indices.contains(measureIndex) else { continue }
            let pass = (passes[measureIndex] ?? 0) + 1
            passes[measureIndex] = pass

            let notatedStartSeconds = timeline.seconds(atTick: Double(notatedStart))
            let notatedEnd = notatedStart + notatedLength
            let beatSeconds = grid.beats.compactMap { beat -> TimeInterval? in
                guard beat.tick >= notatedStart, beat.tick < notatedEnd else { return nil }
                return startSeconds + timeline.seconds(atTick: Double(beat.tick)) - notatedStartSeconds
            }
            let step = grid.stepTicks[measureIndex]
            result.append(PlayedMeasure(
                measureIndex: measureIndex,
                pass: pass,
                startSeconds: startSeconds,
                endSeconds: startSeconds + max(0, timeline.seconds(atTick: Double(notatedEnd)) - notatedStartSeconds),
                beatSeconds: beatSeconds,
                lengthInBeats: Double(notatedLength) / Double(step),
            ))
        }
        return result
    }
}
