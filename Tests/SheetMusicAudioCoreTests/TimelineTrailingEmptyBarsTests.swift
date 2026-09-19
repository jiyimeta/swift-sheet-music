@testable import SheetMusicAudioCore
import SheetMusicCore
import Testing

/// Does the timeline's length count bars that sound nothing?
///
/// Reported 2026-09-20: playback stops at the end of the sounding range rather than at the end of the score. This
/// measures which of the two `totalTicks` reports for a score whose last bars are empty.
@Suite("timeline length over trailing empty bars")
struct TimelineTrailingEmptyBarsTests {
    private static func score(division: Int = 480) -> Score {
        let sounding = Measure(voices: [Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
        ])])
        let empty = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        return Score(
            division: division,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [sounding, empty, empty])],
            )],
        )
    }

    @Test("the timeline runs to the end of the score, not to the last sounding note")
    func lengthCoversTrailingEmptyBars() {
        let score = Self.score()
        let timeline = PlaybackTimeline(score: score)
        // Three 4/4 bars at 480 ppq = 3 × 1920.
        #expect(timeline.totalTicks == 5760)
    }
}
