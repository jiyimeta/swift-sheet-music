import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

// Tuple arrays aren't `Equatable`, so define the test-local comparison
// here. SwiftLint's `static_operator` rule is intentionally bypassed —
// you can't add a static operator to the built-in `Array<(Int, Int)>`.
// swiftlint:disable:next static_operator
private func == (lhs: [(Int, Int)], rhs: [(Int, Int)]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

struct FermataMidiTests {
    private func chord(_ pitch: Int, _ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    private func rest(_ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: []))
    }

    private func fermata(
        _ subtype: String = "fermataAbove",
        stretch: Double? = nil,
    ) -> VoiceElement {
        .fermata(Fermata(subtype: subtype, timeStretch: stretch))
    }

    private func makeScore(
        voices: [[VoiceElement]],
        systemMeasures: [SystemMeasure] = [SystemMeasure()],
    ) -> Score {
        let measure = Measure(voices: voices.map { Voice(elements: $0) })
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "voice",
                articulations: [InstrumentArticulation()],
            ),
            staves: [staff],
        )
        return Score(
            division: 480,
            parts: [part],
            systemMeasures: systemMeasures,
        )
    }

    private func tempoEvents(_ file: MidiFile) -> [(Int, Int)] {
        file.tracks[0].events.compactMap {
            if case let .meta(.tempo(micros)) = $0.event {
                return ($0.tick, micros)
            }
            return nil
        }
    }

    private func micros(_ bpm: Double) -> Int {
        Int((60_000_000.0 / bpm).rounded())
    }

    /// 1. Single normal fermata on quarter at 120 BPM.
    @Test func singleNormalFermataOnQuarter() throws {
        let score = makeScore(voices: [[
            chord(60),
            fermata("fermataAbove"),
            chord(62),
        ]])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        #expect(tempos == [
            (0, micros(120)),
            (480, micros(80)),
            (960, micros(120)),
        ])
    }

    /// 2. Long fermata on rest (grand pause).
    @Test func longFermataOnRest() throws {
        let score = makeScore(voices: [[
            chord(60),
            fermata("fermataLongAbove"),
            rest(.quarter),
            chord(62),
        ]])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        #expect(tempos == [
            (0, micros(120)),
            (480, micros(60)),
            (960, micros(120)),
        ])
    }

    /// 3. Explicit timeStretch override.
    ///
    /// The header-pass emits a default tempo (120 BPM) at tick 0, and the
    /// fermata's open bookend emits its slowed tempo at tick 0 too. Both
    /// appear in the output; the stable sort keeps the bookend AFTER the
    /// header tempo so the bookend wins for playback at tick 0.
    @Test func explicitTimeStretchOverride() throws {
        let score = makeScore(voices: [[
            fermata("fermataAbove", stretch: 2.5),
            chord(60),
        ]])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        #expect(tempos == [
            (0, micros(120)), // header default
            (0, micros(48)), // fermata open (wins per stable sort)
            (480, micros(120)),
        ])
    }

    /// 4. Fermata after chord in MSCX order (backward fallback).
    ///
    /// Header tempo (120) and fermata open (80) co-locate at tick 0 — open
    /// sorts after the header so it wins for playback.
    @Test func fermataAfterChordAnchorsBackwards() throws {
        let score = makeScore(voices: [[
            chord(60),
            fermata("fermataAbove"),
        ]])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        #expect(tempos == [
            (0, micros(120)), // header default
            (0, micros(80)), // fermata open
            (480, micros(120)),
        ])
    }

    /// 5. Same-range fermata in two voices → single bookend pair (max stretch).
    ///
    /// Header tempo at tick 0 plus the merged open bookend at tick 0.
    @Test func sameRangeAcrossVoicesDeduped() throws {
        let score = makeScore(voices: [
            [fermata("fermataAbove"), chord(60)],
            [fermata("fermataLongAbove"), chord(60)],
        ])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        #expect(tempos == [
            (0, micros(120)),
            (0, micros(60)),
            (480, micros(120)),
        ])
    }

    /// 6. Partial overlap → sweep-merge produces correct staircase.
    @Test func partialOverlapTwoVoicesStaircase() throws {
        // Voice 1: dotted-quarter (720 ticks @ div=480) stretch 2.0
        // Voice 2: 8th rest (240 ticks) then quarter (240..720) stretch 1.5
        let dottedQuarter = NoteDuration.fraction(Fraction(numerator: 3, denominator: 8))
        let score = makeScore(voices: [
            [
                fermata("fermataLongAbove"),
                chord(60, dottedQuarter),
            ],
            [
                rest(.eighth),
                fermata("fermataAbove"),
                chord(62, .quarter),
            ],
        ])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        #expect(tempos == [
            (0, micros(120)), // header default
            (0, micros(60)), // merged open bookend
            (720, micros(120)),
        ])
    }

    /// 8. Fermata inside a repeat fires on every iteration.
    @Test func fermataInsideRepeatFiresPerIteration() throws {
        // One measure with startRepeat + endRepeatCount=2, a fermata on
        // the only quarter note. Plays twice. Expect two pairs of
        // tempo bookends (one per iteration), not just one.
        let measure = Measure(
            voices: [Voice(elements: [
                fermata("fermataAbove"),
                chord(60),
            ])],
            startRepeat: true,
            endRepeatCount: 2,
        )
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "voice",
                articulations: [InstrumentArticulation()],
            ),
            staves: [staff],
        )
        let score = Score(division: 480, parts: [part])
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        // Iteration 1 ticks: [0, 480). Iteration 2 ticks: [480, 960).
        // Header tempo at 0 (120). Open bookend at 0 (80). Close at 480.
        // Iteration 2 reset: timeSig+tempo re-emitted at 480 by
        // `isFreshSectionStart` IF measureIndex == 0 — which it is.
        // So at tick 480 we expect: close from iter1 (80→120), then
        // iter2's reset tempo 120, then iter2's open bookend (120→80).
        // At tick 960 we expect close from iter2.
        // Verify the *count* of fermata bookends (open+close pairs):
        // 2 opens at ticks 0 and 480, 2 closes at ticks 480 and 960.
        let opens = tempos.filter { $0.1 == micros(80) }
        let closes = tempos.filter { $0.1 == micros(120) }
        #expect(opens.count == 2, "expected 2 open bookends, got tempos=\(tempos)")
        #expect(
            closes.count(where: { $0.0 == 480 || $0.0 == 960 }) >= 2,
            "expected close bookends at 480 and 960, got tempos=\(tempos)",
        )
    }

    /// 7. End-boundary co-location: .tempo lands at fermata's endTick.
    @Test func endBoundaryTempoChangeWins() throws {
        // Fermata covers [0, 480). At tick 480 a tempo(3.0 bps = 180 BPM)
        // lands. Close emits 180 BPM (timeline lookup post-tempo); tempo
        // also emits 180 BPM. Both at tick 480. Header tempo (120) and
        // fermata open (80) co-locate at tick 0. With the system-level
        // refactor the tempo lives on `systemMeasures` at the 1/4
        // measure position (= tick 480 at division=480).
        let score = makeScore(
            voices: [[
                fermata("fermataAbove"),
                chord(60),
                chord(62),
            ]],
            systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(
                    position: MeasurePosition(numerator: 1, denominator: 4),
                    element: .tempo(Tempo(beatsPerSecond: 3.0)),
                ),
            ])],
        )
        let file = try MidiRenderer.render(score: score)
        let tempos = tempoEvents(file)
        #expect(tempos == [
            (0, micros(120)), // header default
            (0, micros(80)), // fermata open
            (480, micros(180)), // close (sorts before .tempo)
            (480, micros(180)), // .tempo from voice
        ])
    }
}
