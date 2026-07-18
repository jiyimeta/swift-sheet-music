import Foundation
@testable import SheetMusicAudioApple
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI
import Testing

/// Cursor read-path assertions for the unrolled→notated translation:
/// the sequencer plays the UNROLLED SMF while `PlaybackTimeline`
/// frames are NOTATED, so without `PlaybackUnroll` the cursor
/// desyncs on the second pass of any repeat and on every jump. Uses
/// the pure `PlaybackEngine.mappedCursor` seam — no live audio.
struct PlaybackUnrollCursorTests {
    private static let division = 480
    private static let measureTicks = 1920 // 4 quarters in 4/4

    /// `measureCount` bars of 4/4 (four quarter chords each) with an
    /// end-repeat on `repeatMeasure` and optional segno/fine + D.S.
    ///
    /// `repeatMeasure` also gets `startRepeat: true`: an end-repeat
    /// with no matching start-repeat on the same measure loops back to
    /// the implicit *section* start (m0), not to itself — see
    /// `PlaybackUnwindTests.plainRepeatUnrollsTwice` and
    /// `PlaybackUnrollTests.repeatSecondPassMapsBackToNotatedMeasure`'s
    /// doc comment (task-12-report.md). Without it this fixture's plan
    /// would be `[0,1,0,1,2]`, not the single-measure-loop `[0,1,1,2]`
    /// this test's comments assume.
    private static func score(
        measureCount: Int = 3,
        repeatMeasure: Int? = 1,
        dsAlFine: Bool = false,
    ) -> Score {
        var measures: [Measure] = []
        for m in 0 ..< measureCount {
            var elements: [VoiceElement] = []
            if m == 0 {
                elements.append(.timeSignature(TimeSignature(numerator: 4, denominator: 4)))
            }
            for i in 0 ..< 4 {
                elements.append(.chord(Chord(
                    duration: .quarter,
                    notes: [Note(pitch: 60 + i, tpc: 14)],
                )))
            }
            measures.append(Measure(
                voices: [Voice(elements: elements)],
                startRepeat: m == repeatMeasure,
                endRepeatCount: m == repeatMeasure ? 2 : nil,
                markers: dsAlFine && m == 1 ? [Marker(kind: .segno)]
                    : dsAlFine && m == 2 ? [Marker(kind: .fine)] : [],
                jumps: dsAlFine && m == measureCount - 1
                    ? [Jump(jumpTo: "segno", playUntil: "fine")] : [],
            ))
        }
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        let systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2.0))),
        ])] + Array(repeating: SystemMeasure(), count: max(0, measureCount - 1))
        return Score(division: division, parts: [part], systemMeasures: systemMeasures, metaTags: [:])
    }

    @Test func cursorFollowsSecondPassOfARepeat() {
        // [m0, m1(:||x2), m2] → plan [0,1,1,2]. Raw sequencer tick
        // 4320 = second pass of m1, beat 2 → notated 2400.
        let score = Self.score()
        let timeline = PlaybackTimeline(score: score)
        let unroll = MidiRenderer.playbackUnroll(score: score)
        let mapped = PlaybackEngine.mappedCursor(
            rawSequencerTick: 2 * Self.measureTicks + 480,
            sequenceMap: .identity,
            timeline: timeline,
            unroll: unroll,
        )
        #expect(mapped == timeline.frame(atTick: Self.measureTicks + 480)?.cursor)
        // Without the map the raw tick would clamp forward into m2 —
        // the pre-existing repeat desync this task fixes.
        #expect(mapped != timeline.frame(atTick: 2 * Self.measureTicks + 480)?.cursor)
    }

    @Test func cursorFollowsAJumpBackToTheSegno() {
        // D.S. al Fine on 4 measures (no repeat): plan [0,1,2,3, 1,2].
        // The 5th measure-play (raw 4*1920) is notated m1.
        let score = Self.score(measureCount: 4, repeatMeasure: nil, dsAlFine: true)
        let timeline = PlaybackTimeline(score: score)
        let unroll = MidiRenderer.playbackUnroll(score: score)
        let mapped = PlaybackEngine.mappedCursor(
            rawSequencerTick: 4 * Self.measureTicks,
            sequenceMap: .identity,
            timeline: timeline,
            unroll: unroll,
        )
        #expect(mapped == timeline.frame(atTick: Self.measureTicks)?.cursor)
    }

    @Test func preRollStillPinsAndDefaultsToIdentity() {
        let score = Self.score()
        let timeline = PlaybackTimeline(score: score)
        let unroll = MidiRenderer.playbackUnroll(score: score)
        let map = SequenceMap(preRollTicks: 1920, baseTick: 0)
        // Inside the pre-roll → nil regardless of the unroll map.
        #expect(PlaybackEngine.mappedCursor(
            rawSequencerTick: 100, sequenceMap: map,
            timeline: timeline, unroll: unroll,
        ) == nil)
        // Omitting `unroll` keeps the legacy behavior (identity).
        #expect(PlaybackEngine.mappedCursor(
            rawSequencerTick: 480, sequenceMap: .identity, timeline: timeline,
        ) == timeline.frame(atTick: 480)?.cursor)
    }
}
