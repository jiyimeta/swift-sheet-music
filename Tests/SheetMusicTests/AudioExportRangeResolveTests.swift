@testable import SheetMusicAudioCore
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite("AudioExportRange.resolveTickRange")
struct AudioExportRangeResolveTests {
    /// Two 4/4 measures × four quarter notes at division 480.
    /// Onsets: ticks {0, 480, 960, 1440, 1920, 2400, 2880, 3360}.
    /// Total ticks: 3840 (end of measure 2).
    private func twoBarFourFourScore() -> Score {
        let quarter = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
        )
        let firstVoice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
        ])
        let restVoice = Voice(elements: [
            .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
        ])
        let staff = Staff(measures: [
            Measure(voices: [firstVoice]),
            Measure(voices: [restVoice]),
        ])
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "i",
                articulations: [InstrumentArticulation()],
            ),
            staves: [staff],
        )
        return Score(division: 480, parts: [part])
    }

    private func note(measure: Int, element: Int) -> NoteID {
        NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measure,
            voiceIndex: 0,
            elementIndex: element,
            noteIndexInChord: 0,
        )
    }

    @Test(".full returns (0, totalTicks)")
    func fullReturnsWholeRange() throws {
        let score = twoBarFourFourScore()
        let timeline = PlaybackTimeline(score: score)

        let range = try AudioExportRange.full.resolveTickRange(
            timeline: timeline, loop: nil,
        )
        #expect(range.startTick == 0)
        #expect(range.endTick == timeline.totalTicks)
        #expect(range.endTick == 3840)
    }

    @Test(".currentLoop with a loop set returns the loop bounds")
    func currentLoopUsesLoopRange() throws {
        let score = twoBarFourFourScore()
        let timeline = PlaybackTimeline(score: score)
        let loop = LoopRange(startTick: 480, endTick: 1920)

        let range = try AudioExportRange.currentLoop.resolveTickRange(
            timeline: timeline, loop: loop,
        )
        #expect(range.startTick == 480)
        #expect(range.endTick == 1920)
    }

    @Test(".currentLoop with nil loop falls back to full range")
    func currentLoopWithoutLoopFallsBackToFull() throws {
        let score = twoBarFourFourScore()
        let timeline = PlaybackTimeline(score: score)

        let range = try AudioExportRange.currentLoop.resolveTickRange(
            timeline: timeline, loop: nil,
        )
        #expect(range.startTick == 0)
        #expect(range.endTick == timeline.totalTicks)
    }

    @Test(".region with valid item cursors returns their ticks")
    func regionWithValidCursors() throws {
        let score = twoBarFourFourScore()
        let timeline = PlaybackTimeline(score: score)

        // Measure 0 element 2 (after TS at element 0) → tick 480;
        // measure 1 element 0 → tick 1920.
        let from: ScoreCursor = .item(.note(note(measure: 0, element: 2)))
        let to: ScoreCursor = .item(.note(note(measure: 1, element: 0)))

        let range = try AudioExportRange.region(from: from, to: to)
            .resolveTickRange(timeline: timeline, loop: nil)
        #expect(range.startTick == 480)
        #expect(range.endTick == 1920)
    }

    @Test(".region with an unknown cursor throws rangeNotInTimeline")
    func regionWithUnknownCursorThrows() {
        let score = twoBarFourFourScore()
        let timeline = PlaybackTimeline(score: score)

        let from: ScoreCursor = .item(.note(note(measure: 0, element: 1)))
        // measureIndex = 99 doesn't exist in this 2-bar score.
        let to: ScoreCursor = .beat(measureIndex: 99, tickInMeasure: 0)

        #expect(throws: AudioExportError.rangeNotInTimeline) {
            try AudioExportRange.region(from: from, to: to)
                .resolveTickRange(timeline: timeline, loop: nil)
        }
    }

    @Test(".regionThroughEnd returns (fromTick, itemEndTicks[last])")
    func regionThroughEndUsesItemEndTick() throws {
        let score = twoBarFourFourScore()
        let timeline = PlaybackTimeline(score: score)

        // from: measure 0 element 0 → tick 0.
        // last: measure 1 element 3 → onset 3360, end 3840 (quarter @ 480).
        let from: ScoreCursor = .item(.note(note(measure: 0, element: 1)))
        let lastID: ScoreItemID = .note(note(measure: 1, element: 3))

        let range = try AudioExportRange.regionThroughEnd(from: from, last: lastID)
            .resolveTickRange(timeline: timeline, loop: nil)
        #expect(range.startTick == 0)
        #expect(range.endTick == 3840)
        #expect(range.endTick == timeline.itemEndTicks[lastID])
    }

    @Test(".regionThroughEnd with unknown last item throws rangeNotInTimeline")
    func regionThroughEndUnknownLastThrows() {
        let score = twoBarFourFourScore()
        let timeline = PlaybackTimeline(score: score)

        let from: ScoreCursor = .item(.note(note(measure: 0, element: 1)))
        // measure 9 doesn't exist.
        let unknownLast: ScoreItemID = .note(note(measure: 9, element: 0))

        #expect(throws: AudioExportError.rangeNotInTimeline) {
            try AudioExportRange.regionThroughEnd(from: from, last: unknownLast)
                .resolveTickRange(timeline: timeline, loop: nil)
        }
    }

    /// `.beat` cursors falling on a tick that's already occupied by a
    /// chord get deduped out of `frames`. The resolver must still
    /// recover the tick by deriving it from `measureStartTick + tim`.
    @Test(".beat cursor on a chord-occupied tick resolves via measureStart")
    func beatCursorFallsBackViaMeasureStart() throws {
        let score = twoBarFourFourScore()
        let timeline = PlaybackTimeline(score: score)

        // Every chord onset occupies its tick, so beat 0 of measure 1
        // (absolute tick 1920) collides with the chord onset there and
        // gets deduped out of `frames`. PlaybackTimeline.frame(forCursor:)
        // now has a tick-based fallback; resolveTickRange must benefit
        // from it.
        let beatAtChordTick: ScoreCursor = .beat(measureIndex: 1, tickInMeasure: 0)
        let to: ScoreCursor = .item(.note(note(measure: 1, element: 2)))

        let range = try AudioExportRange.region(from: beatAtChordTick, to: to)
            .resolveTickRange(timeline: timeline, loop: nil)
        #expect(range.startTick == 1920)
        #expect(range.endTick == 2880)
    }
}
