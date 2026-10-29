@testable import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicMIDI
import Testing

struct PlayedMeasureTests {
    private static let division = 480

    /// One voice-0 measure holding a single chord of `duration` (a whole note fills a 4/4 bar).
    private static func measure(
        duration: NoteDuration = .whole,
        timeSignature: TimeSignature? = nil,
        startRepeat: Bool = false,
        endRepeat: Int? = nil,
        actualLength: Fraction? = nil,
        irregular: Bool = false,
    ) -> Measure {
        var elements: [VoiceElement] = []
        if let timeSignature { elements.append(.timeSignature(timeSignature)) }
        elements.append(.chord(Chord(duration: duration, notes: [Note(pitch: 60, tpc: 14)])))
        return Measure(
            voices: [Voice(elements: elements)],
            startRepeat: startRepeat,
            endRepeatCount: endRepeat,
            actualLength: actualLength,
            irregular: irregular,
        )
    }

    /// `tempos` maps a measure index to the beats per second that starts there; measure 0 defaults to 2 (120 BPM).
    private static func score(_ measures: [Measure], tempos: [Int: Double] = [0: 2.0]) -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        let systemMeasures = measures.indices.map { index -> SystemMeasure in
            guard let beatsPerSecond = tempos[index] else { return SystemMeasure() }
            return SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: beatsPerSecond))),
            ])
        }
        return Score(division: division, parts: [part], systemMeasures: IdentifiedArray(systemMeasures), metaTags: [:])
    }

    @Test func aPlainFourMeasureScoreAtOneTwentyBPM() {
        let played = PlayedMeasures.make(score: Self.score(Array(repeating: Self.measure(), count: 4)))
        #expect(played.count == 4)
        #expect(played.map(\.measureIndex) == [0, 1, 2, 3])
        #expect(played.map(\.pass) == [1, 1, 1, 1])
        #expect(played.map(\.startSeconds) == [0, 2, 4, 6])
        #expect(played.map(\.endSeconds) == [2, 4, 6, 8])
        #expect(played[1].beatSeconds == [2.0, 2.5, 3.0, 3.5])
        #expect(played.map(\.lengthInBeats) == [4, 4, 4, 4])
    }

    @Test func aRepeatedMeasureGetsPassesOneAndTwoOnConsecutiveStretches() {
        let played = PlayedMeasures.make(score: Self.score([
            Self.measure(startRepeat: true, endRepeat: 2), Self.measure(),
        ]))
        #expect(played.map(\.measureIndex) == [0, 0, 1])
        #expect(played.map(\.pass) == [1, 2, 1])
        #expect(played.map(\.startSeconds) == [0, 2, 4])
        #expect(played[1].beatSeconds == [2.0, 2.5, 3.0, 3.5])
    }

    @Test func aZeroLengthMeasureInsideARepeatIsAttributedToItself() {
        // m1 has an empty voice 0, so it starts on the same tick as m2. A lookup by start tick would credit its
        // plays to m2; the span carries the real index.
        let empty = Measure(voices: [Voice(elements: [])], startRepeat: true, endRepeatCount: 2)
        let played = PlayedMeasures.make(score: Self.score([Self.measure(), empty, Self.measure()]))
        #expect(played.map(\.measureIndex) == [0, 1, 1, 2])
        #expect(played.map(\.pass) == [1, 1, 2, 1])
        #expect(played[1].beatSeconds.isEmpty)
        #expect(played[1].lengthInBeats == 0)
        #expect(played[3].lengthInBeats == 4)
    }

    @Test func anEighthNotePickup() {
        let played = PlayedMeasures.make(score: Self.score([
            Self.measure(duration: .eighth, actualLength: Fraction(numerator: 1, denominator: 8), irregular: true),
            Self.measure(),
        ]))
        #expect(played.count == 2)
        #expect(played[0].lengthInBeats == 0.5)
        #expect(played[0].beatSeconds == [0.0])
        #expect(played[0].endSeconds == 0.25)
        #expect(played[1].startSeconds == 0.25)
        #expect(played[1].lengthInBeats == 4)
    }

    @Test func sixEightCountsEighths() {
        let sixEight = TimeSignature(numerator: 6, denominator: 8)
        let played = PlayedMeasures.make(score: Self.score([
            Self.measure(duration: .half.dotted(1), timeSignature: sixEight), Self.measure(duration: .half.dotted(1)),
        ]))
        #expect(played.map(\.beatSeconds.count) == [6, 6])
        #expect(played.map(\.lengthInBeats) == [6, 6])
    }

    @Test func beatSecondsEqualTheUnrolledClickTrack() {
        let score = Self.score(
            [
                Self.measure(startRepeat: true, endRepeat: 2), Self.measure(), Self.measure(),
            ],
            tempos: [0: 2.0, 1: 3.0],
        )
        let played = PlayedMeasures.make(score: score)
        #expect(played.map(\.measureIndex) == [0, 0, 1, 2])

        let timeline = PlaybackTimeline(score: score)
        let unroll = MidiRenderer.playbackUnroll(score: score)
        let timeMap = UnrolledTimeMap(unroll: unroll, timeline: timeline)
        let click = PlaybackTimeline.unrolledMetronomeBeats(score: score, unroll: unroll)
        // The click's own definition of each beat's transport second: its span's start on the unrolled axis plus the
        // notated seconds the beat sits past the span's notated start.
        let expected = click.map { beat -> TimeInterval in
            let spanIndex = unroll.spans.lastIndex { $0.unrolledStart <= beat.tick } ?? 0
            let span = unroll.spans[spanIndex]
            let notatedTick = Double(span.notatedStart + beat.tick - span.unrolledStart)
            return timeMap.spanStartSeconds[spanIndex]
                + timeline.seconds(atTick: notatedTick) - timeline.seconds(atTick: Double(span.notatedStart))
        }
        let actual = played.flatMap(\.beatSeconds)
        #expect(actual.count == click.count)
        #expect(actual.count == 16)
        for (a, e) in zip(actual, expected) {
            #expect(abs(a - e) < 1e-9)
        }
        // m1 plays at 180 BPM: 1.3333 s per bar, so the tempo change really is in the data under test.
        // (The timeline rounds a tempo to whole microseconds per beat, hence the tolerance.)
        #expect(abs(played[2].endSeconds - played[2].startSeconds - 4.0 / 3.0) < 1e-4)
    }
}
