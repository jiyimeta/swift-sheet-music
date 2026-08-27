import Foundation
@testable import SheetMusicAudioCore
import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// The two remaining places where a clock disagreed with what a listener hears: the
/// measure-granular notated-time API ignored fermata holds, and the cursor's own lookup ignored
/// swing.
@Suite("Notated time: fermata holds and swing")
struct NotatedTimeHoldAndSwingTests {
    private static let division = 480

    private static func instrument() -> Instrument {
        Instrument(id: "i", articulations: [InstrumentArticulation()])
    }

    // MARK: - Fermata holds in the notated-time API

    /// Two 4/4 bars: `[fermata, half, half]` then four quarters. At the default 120 BPM the
    /// straight duration is 4 s and a standard `fermataAbove` (stretch 1.5) on the first half
    /// note adds 0.5 s.
    private static func fermataScore() -> Score {
        let m0 = Measure(voices: [Voice(elements: [
            .fermata(Fermata(subtype: "fermataAbove")),
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .half, notes: [Note(pitch: 62, tpc: 16)])),
        ])])
        let m1 = Measure(voices: [Voice(elements: (0 ..< 4).map { i in
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 64 + i, tpc: 18)]))
        })])
        return Score(
            division: division,
            parts: [Part(id: "P1", instrument: instrument(), staves: [Staff(measures: [m0, m1])])],
        )
    }

    @Test("fermataHolds anchors the fermata to the chord it holds")
    func holdsAnchorToTheChord() {
        let holds = Self.fermataScore().fermataHolds()
        #expect(holds == [FermataHold(
            measureIndex: 0, startTickInMeasure: 0, ticks: 960, stretch: 1.5,
        )])
        #expect(abs((holds.first?.extraTicks ?? 0) - 480) < 0.001)
    }

    /// Regression: `notatedDurationSeconds` summed each bar's tick length at its governing
    /// tempo and stopped there, so a piece with fermatas reported as shorter than it plays —
    /// the seek bar's total, and every elapsed readout derived from it, ran short by the sum of
    /// every hold.
    @Test("notated duration includes the holds")
    func durationIncludesHolds() {
        #expect(abs(Self.fermataScore().notatedDurationSeconds - 4.5) < 0.001)
    }

    @Test("seconds(at:) carries the hold into every later bar")
    func secondsCarriesTheHold() {
        let score = Self.fermataScore()
        // Bar 2's downbeat: 2 s of notated content plus the 0.5 s hold in bar 1.
        #expect(abs(score.seconds(at: .beat(measureIndex: 1, tickInMeasure: 0)) - 2.5) < 0.001)
    }

    @Test("cursor(atSeconds:) is the inverse of seconds(at:) across a hold")
    func cursorAtSecondsInverts() {
        let score = Self.fermataScore()
        let cursor = score.cursor(atSeconds: 2.5)
        #expect(cursor.measureIndex == 1)
        #expect(score.tickInMeasure(of: cursor) == 0)
    }

    @Test("a score without fermatas is unchanged")
    func noFermataIsUnchanged() {
        let bar = Measure(voices: [Voice(elements: (0 ..< 4).map { i in
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60 + i, tpc: 14)]))
        })])
        let score = Score(
            division: Self.division,
            parts: [Part(
                id: "P1", instrument: Self.instrument(), staves: [Staff(measures: [bar, bar])],
            )],
        )
        #expect(abs(score.notatedDurationSeconds - 4) < 0.001)
        #expect(score.fermataHolds().isEmpty)
    }

    // MARK: - Swing

    /// One 4/4 bar of straight eighths with score-level swing (eighth unit, ratio 60). The
    /// renderer pushes each up-beat late by `(60-50)/100` of the swung pair: the pair is
    /// 2 x 240 = 480 ticks, so the shift is 48 ticks = 0.05 s at 120 BPM.
    private static func swungScore() -> Score {
        let eighths = Voice(elements: (0 ..< 8).map { i in
            .chord(Chord(duration: .eighth, notes: [Note(pitch: 60 + i, tpc: 14)]))
        })
        var style = ScoreStyle.museScoreDefaults
        style.swingUnit = .eighth
        style.swingRatio = 60
        return Score(
            division: division,
            parts: [Part(
                id: "P1", instrument: instrument(),
                staves: [Staff(measures: [Measure(voices: [eighths])])],
            )],
            style: style,
        )
    }

    @Test("swing shifts the up-beats and leaves the down-beats alone")
    func swingShiftsUpBeats() {
        let shifts = MidiRenderer.swingOnsetShifts(score: Self.swungScore())
        func shift(element: Int) -> Int? {
            shifts[.note(NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: element, noteIndexInChord: 0,
            ))]
        }
        for downbeat in [0, 2, 4, 6] {
            #expect(shift(element: downbeat) == nil)
        }
        for upbeat in [1, 3, 5, 7] {
            #expect(shift(element: upbeat) == 48)
        }
    }

    /// Regression: the cursor's lookup searched the grid onset, so it stepped onto a swung
    /// eighth a tenth of a beat before that note was heard.
    @Test("the cursor's lookup follows the audible onset")
    func frameAtTimeFollowsTheAudibleOnset() throws {
        let timeline = PlaybackTimeline(score: Self.swungScore())
        // The second eighth: grid onset 0.25 s, heard 0.05 s later.
        let upbeat = try #require(timeline.frames.first { $0.tick == 240 })
        #expect(abs(upbeat.timeSeconds - 0.25) < 0.001)
        #expect(abs(upbeat.soundedTimeSeconds - 0.3) < 0.001)

        // At 0.27 s the note has not sounded yet, so the cursor is still on the down-beat.
        #expect(timeline.frame(atTime: 0.27)?.tick == 0)
        #expect(timeline.frame(atTime: 0.31)?.tick == 240)
    }

    @Test("swing leaves the tick clock and the total alone")
    func swingDoesNotMoveTheClock() {
        let timeline = PlaybackTimeline(score: Self.swungScore())
        #expect(abs(timeline.seconds(atTick: 240) - 0.25) < 0.001)
        #expect(timeline.frame(atTick: 240)?.tick == 240)
        #expect(abs(timeline.totalSeconds - 2) < 0.001)
    }

    @Test("without swing the audible and grid onsets are the same")
    func withoutSwingBothOnsetsAgree() {
        let timeline = PlaybackTimeline(score: Self.fermataScore())
        #expect(timeline.frames.allSatisfy {
            abs($0.soundedTimeSeconds - $0.timeSeconds) < 1e-12
        })
    }
}
