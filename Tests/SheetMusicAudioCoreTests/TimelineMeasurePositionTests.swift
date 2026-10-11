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
}
