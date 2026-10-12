@testable import SheetMusicAudioCore
import SheetMusicCore
import Testing

/// A transport position as a measure and an offset, the coordinate a score swap carries it across an edit in.
@Suite("timeline measure positions")
struct TimelineMeasurePositionTests {
    /// `measureCount` 4/4 measures of quarter notes at 480 ppq, so measure `m` starts at `m × 1920`.
    private static func score(measureCount: Int) -> Score {
        let measures = (0 ..< measureCount).map { index in
            let timeSignature: [VoiceElement] = index == 0
                ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                : []
            let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
            return Measure(voices: [Voice(elements: timeSignature + Array(repeating: .chord(quarter), count: 4))])
        }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: measures)])],
        )
    }

    @Test("a tick is the measure it falls in and its offset there")
    func tickBecomesMeasureAndOffset() {
        let timeline = PlaybackTimeline(score: Self.score(measureCount: 3))

        #expect(timeline.measurePosition(ofTick: 0) == PlaybackMeasurePosition(measureIndex: 0, tickInMeasure: 0))
        #expect(timeline.measurePosition(ofTick: 2400) == PlaybackMeasurePosition(measureIndex: 1, tickInMeasure: 480))
        #expect(timeline.measurePosition(ofTick: 5760) == PlaybackMeasurePosition(measureIndex: 2, tickInMeasure: 1920))
    }

    @Test("a position comes back as the same tick in the same score")
    func positionRoundTrips() throws {
        let timeline = PlaybackTimeline(score: Self.score(measureCount: 3))

        let position = try #require(timeline.measurePosition(ofTick: 4320))

        #expect(timeline.tick(at: position) == 4320)
    }

    @Test("a measure the edit removed becomes the start of the last measure")
    func removedMeasureClampsToLastStart() {
        let shorter = PlaybackTimeline(score: Self.score(measureCount: 2))

        let tick = shorter.tick(at: PlaybackMeasurePosition(measureIndex: 2, tickInMeasure: 960))

        #expect(tick == 1920)
    }

    @Test("an offset past the end of its measure becomes that end")
    func offsetClampsToMeasureEnd() {
        let timeline = PlaybackTimeline(score: Self.score(measureCount: 2))

        #expect(timeline.tick(at: PlaybackMeasurePosition(measureIndex: 0, tickInMeasure: 5000)) == 1920)
        #expect(timeline.tick(at: PlaybackMeasurePosition(measureIndex: 1, tickInMeasure: 5000)) == 3840)
    }

    @Test("a cursor is the measure and offset of its frame, and that position is a cursor again")
    func cursorRoundTripsThroughAPosition() throws {
        let timeline = PlaybackTimeline(score: Self.score(measureCount: 3))
        let cursor = try #require(timeline.frame(atTick: 2400)?.cursor)

        let position = try #require(timeline.measurePosition(ofCursor: cursor))

        #expect(position == PlaybackMeasurePosition(measureIndex: 1, tickInMeasure: 480))
        #expect(timeline.cursor(at: position) == cursor)
    }

    @Test("a cursor at a measure the edit removed lands on the start of the last measure")
    func cursorPastTheEndLandsOnTheLastMeasure() throws {
        let shorter = PlaybackTimeline(score: Self.score(measureCount: 2))

        let cursor = try #require(shorter.cursor(at: PlaybackMeasurePosition(measureIndex: 2, tickInMeasure: 960)))

        #expect(shorter.frame(forCursor: cursor)?.tick == 1920)
    }

    @Test("a loop keeps its measures and offsets")
    func loopRoundTripsThroughMeasures() throws {
        let timeline = PlaybackTimeline(score: Self.score(measureCount: 3))
        let range = LoopRange(startTick: 2400, endTick: 4320)

        let loop = try #require(timeline.measureLoop(of: range))

        #expect(loop.start == PlaybackMeasurePosition(measureIndex: 1, tickInMeasure: 480))
        #expect(loop.end == PlaybackMeasurePosition(measureIndex: 2, tickInMeasure: 480))
        #expect(timeline.loopRange(at: loop) == range)
    }

    @Test("a loop the edit left spanning nothing is no loop")
    func loopClampedOntoOneTickIsNil() {
        let shorter = PlaybackTimeline(score: Self.score(measureCount: 2))
        // Both ends sat in measures the edit removed, so both clamp to the start of the last one.
        let loop = PlaybackMeasureLoop(
            start: PlaybackMeasurePosition(measureIndex: 2, tickInMeasure: 0),
            end: PlaybackMeasurePosition(measureIndex: 3, tickInMeasure: 0),
        )

        #expect(shorter.loopRange(at: loop) == nil)
    }
}
