import Foundation
@testable import SheetMusicAudioCore
import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// `PlaybackTimeline.unrolledMetronomeBeats(score:)` projects the NOTATED
/// body metronome beats (`PlaybackTimeline.metronomeBeats`) onto the
/// UNROLLED sequencer timeline (repeats + jumps expanded), so the BODY
/// click track keeps sounding on a repeat's 2nd pass instead of going
/// silent once playback runs past the (shorter) notated length. See
/// `PlaybackUnroll.unrolledTicks(forNotated:)`.
struct UnrolledMetronomeBeatsTests {
    private static let division = 480
    private static let span = 1920 // whole note in 4/4 @ 480

    private static func measure(startRepeat: Bool = false, endRepeat: Int? = nil) -> Measure {
        Measure(
            voices: [Voice(elements: [.chord(Chord(
                duration: .whole,
                notes: [Note(pitch: 60, tpc: 14)],
            ))])],
            startRepeat: startRepeat,
            endRepeatCount: endRepeat,
        )
    }

    private static func score(_ measures: [Measure]) -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        return Score(division: division, parts: [part])
    }

    @Test func repeatedMeasureBeatsAppearTwiceSorted() {
        // [m0, m1(||:x2:||), m2] → plan [0,1,1,2] (see PlaybackUnrollTests
        // for the same shape). m1's 4 beats should appear once per pass.
        let s = Self.score([
            Self.measure(), Self.measure(startRepeat: true, endRepeat: 2), Self.measure(),
        ])
        let notated = PlaybackTimeline.metronomeBeats(score: s)
        let unrolled = PlaybackTimeline.unrolledMetronomeBeats(score: s)

        // Notated has 4 beats/measure * 3 measures = 12; unrolled adds
        // the repeated measure's 4 beats again = 16.
        #expect(notated.count == 12)
        #expect(unrolled.count == 16)

        // Sorted ascending by tick.
        for i in 1 ..< unrolled.count {
            #expect(unrolled[i].tick >= unrolled[i - 1].tick)
        }

        // m1's downbeat (notated tick == span) appears at BOTH its
        // first-pass unrolled tick (== span, unchanged) and its
        // second-pass unrolled tick (== 2*span) — the two occurrences
        // PlaybackUnrollTests' `unrolledTicksMapsRepeatedMeasureToBothOccurrences`
        // pins for the same score shape.
        let m1DownbeatOccurrences = unrolled.filter {
            $0.tick == Self.span || $0.tick == 2 * Self.span
        }
        #expect(m1DownbeatOccurrences.count == 2)
        #expect(m1DownbeatOccurrences.map(\.isDownbeat) == [true, true])
    }

    @Test func jumpFreeScoreUnrolledEqualsNotated() {
        let s = Self.score([Self.measure(), Self.measure(), Self.measure()])
        let notated = PlaybackTimeline.metronomeBeats(score: s)
        let unrolled = PlaybackTimeline.unrolledMetronomeBeats(score: s)
        #expect(unrolled.count == notated.count)
        #expect(unrolled == notated)
    }
}
